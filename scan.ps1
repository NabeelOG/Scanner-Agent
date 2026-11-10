param(
    [string]$OutputPath
)

# ---------------------------------------------------------------------------
# Scans one page and writes it to $OutputPath as a JPEG.
#
# Exit codes:
#   0  success, a JPEG was written
#   1  anything went wrong, with the reason on stderr
#
# Why the conversion below exists:
#
# WIA does not honour the requested image format. Asking this scanner for
# JPEG made it hand back an uncompressed 24-bit BMP instead, about 25 MB for
# a single A4 page, while still reporting success. The agent then served those
# bytes labelled image/jpeg. So the page is captured and then converted to
# JPEG here. The bytes are checked rather than assumed, so this stays correct
# on scanners that do support JPEG.
#
# The resolution is also stamped onto the JPEG. The conversion loses it, and
# an image holding 300 DPI worth of pixels but claiming 96 DPI prints as a
# 25 by 36 inch poster.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$scanDpi = 300
$wiaFormatBMP = '{B96B3CAB-0728-11D3-9D7B-0000F81EF32E}'
$jpegMimeType = 'image/jpeg'
$jpegQuality = 85
$transferAttempts = 3

# Writes to stderr rather than using Write-Error, which wraps the message in
# PowerShell's own error formatting and buries it under CategoryInfo noise.
function Write-Failure([string]$Message) {
    [Console]::Error.WriteLine($Message)
    exit 1
}

# A JPEG is only a real scan if it contains a start-of-frame marker, which is
# where the actual picture data begins. A file that is just a header with no
# frame inside it means the transfer did not complete.
function Test-HasImageData([byte[]]$Bytes) {
    for ($i = 2; $i -lt ($Bytes.Length - 1); $i++) {
        if ($Bytes[$i] -ne 0xFF) { continue }

        $marker = $Bytes[$i + 1]

        # Start-of-frame markers, minus the ones that are not frames.
        if ($marker -ge 0xC0 -and $marker -le 0xCF -and
            $marker -ne 0xC4 -and $marker -ne 0xC8 -and $marker -ne 0xCC) {
            return $true
        }
    }
    return $false
}

function Save-AsJpeg([System.Drawing.Image]$Source, [string]$Path, [int]$Dpi) {
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
        Where-Object { $_.MimeType -eq $jpegMimeType }

    if (-not $codec) { throw 'This system has no JPEG encoder available.' }

    $settings = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $settings.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
        [System.Drawing.Imaging.Encoder]::Quality, [long]$jpegQuality)

    # Copied into a fresh 24-bit bitmap rather than saved straight from the
    # source. This forces a format the JPEG encoder accepts, since a 32-bit
    # scan carries an alpha channel JPEG cannot store, and it is where the
    # resolution is set so the encoder records it.
    $canvas = New-Object System.Drawing.Bitmap(
        $Source.Width, $Source.Height,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)

    $canvas.SetResolution($Dpi, $Dpi)

    $graphics = [System.Drawing.Graphics]::FromImage($canvas)
    $graphics.Clear([System.Drawing.Color]::White)

    # The destination rectangle is given in pixels on purpose.
    #
    # The short DrawImage(source, x, y) form draws the image at its physical
    # size, which is derived from the source resolution. A scan decoded from
    # the driver reports 96 DPI, so against this 300 DPI canvas that form
    # magnifies the picture by just over three times, overflows the canvas and
    # leaves only the top left corner visible. Passing both rectangles with
    # GraphicsUnit.Pixel copies the pixels across one for one instead.
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $graphics.DrawImage(
        $Source,
        (New-Object System.Drawing.Rectangle 0, 0, $Source.Width, $Source.Height),
        0, 0, $Source.Width, $Source.Height,
        [System.Drawing.GraphicsUnit]::Pixel)

    $graphics.Dispose()

    try {
        $canvas.Save($Path, $codec, $settings)
    }
    finally {
        $canvas.Dispose()
    }
}

$rawPath = $null

try {
    if (-not $OutputPath) { Write-Failure 'No output path was given.' }

    $deviceManager = New-Object -ComObject WIA.DeviceManager

    if ($deviceManager.DeviceInfos.Count -eq 0) {
        Write-Failure 'No scanner found.'
    }

    $scanner = $deviceManager.DeviceInfos.Item(1).Connect()
    $item = $scanner.Items.Item(1)

    $item.Properties('Horizontal Resolution').Value = $scanDpi
    $item.Properties('Vertical Resolution').Value = $scanDpi

    # Scanned to a temporary file first, so a failed conversion cannot leave a
    # half written file where the caller expects a finished scan.
    $rawPath = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        ([System.Guid]::NewGuid().ToString() + '.bmp'))

    # A transfer occasionally fails with a bare COM "Unspecified error" when
    # the scanner is still busy from the previous page, so it is retried
    # rather than failing the whole scan on the first wobble.
    $transferred = $false
    $lastError = $null

    for ($attempt = 1; $attempt -le $transferAttempts; $attempt++) {
        try {
            $image = $item.Transfer($wiaFormatBMP)
            $image.SaveFile($rawPath)
            $transferred = $true
            break
        }
        catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Seconds 2
        }
    }

    if (-not $transferred) {
        Write-Failure ("The scanner did not complete the transfer. " + $lastError)
    }

    $raw = [System.IO.File]::ReadAllBytes($rawPath)

    if ($raw.Length -lt 4) { Write-Failure 'The scanner produced an empty file.' }

    $isJpeg = ($raw[0] -eq 0xFF -and $raw[1] -eq 0xD8)
    $isBmp = ($raw[0] -eq 0x42 -and $raw[1] -eq 0x4D)

    if ($isJpeg) {
        # The driver gave a JPEG after all, so nothing needs converting.
        [System.IO.File]::WriteAllBytes($OutputPath, $raw)
    }
    elseif ($isBmp) {
        Add-Type -AssemblyName System.Drawing

        # Read through a stream rather than FromFile, which would hold the
        # temporary file open and stop it being deleted afterwards.
        $rawStream = New-Object System.IO.MemoryStream(,$raw)
        $decoded = [System.Drawing.Image]::FromStream($rawStream)

        try {
            $sourceWidth = $decoded.Width
            $sourceHeight = $decoded.Height

            Save-AsJpeg $decoded $OutputPath $scanDpi
        }
        finally {
            $decoded.Dispose()
            $rawStream.Dispose()
        }

        # Guard against the conversion quietly resizing the picture, which
        # would silently crop the page rather than fail.
        $written = [System.Drawing.Image]::FromFile($OutputPath)
        try {
            if ($written.Width -ne $sourceWidth -or $written.Height -ne $sourceHeight) {
                Write-Failure ('The converted image came out the wrong size, ' +
                    $written.Width + 'x' + $written.Height +
                    ' instead of ' + $sourceWidth + 'x' + $sourceHeight + '.')
            }
        }
        finally {
            $written.Dispose()
        }
    }
    else {
        Write-Failure ('The scanner produced an unrecognised image format, first bytes {0:X2} {1:X2}.' -f $raw[0], $raw[1])
    }

    if (-not (Test-Path $OutputPath)) { Write-Failure 'No image file was produced.' }

    $final = [System.IO.File]::ReadAllBytes($OutputPath)

    if (-not (Test-HasImageData $final)) {
        Write-Failure 'The scanner returned an image with no picture data in it. Try scanning again.'
    }

    Write-Output 'OK'
    exit 0
}
catch {
    Write-Failure $_.Exception.Message
}
finally {
    if ($rawPath -and (Test-Path $rawPath)) {
        Remove-Item -LiteralPath $rawPath -Force -ErrorAction SilentlyContinue
    }
}
