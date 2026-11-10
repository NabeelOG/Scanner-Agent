package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const version = "1.0.0"

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/scan", scan)

	srv := &http.Server{
		Addr:              "127.0.0.1:8081",
		Handler:           cors(mux),
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      10 * time.Minute,
	}

	log.Println("WARNING: every website the user visits can drive this scanner")

	log.Fatal(srv.ListenAndServe())
}

// cors answers preflights and marks the response readable by any origin.
// Chrome also needs Access-Control-Allow-Private-Network before it will
// offer its "allow this site to reach your device" prompt for a page on
// https calling a loopback address.
func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != "" {
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", "*")
			h.Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

			// Authorization has to be permitted because the app's JWT
			// interceptor adds a bearer token to every request it makes,
			// including this one. Without it the browser sends a preflight,
			// that preflight is refused, and the scan never leaves the
			// machine. The agent ignores the token; allowing the header
			// only stops the request being blocked before it arrives.
			h.Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
			h.Set("Access-Control-Allow-Private-Network", "true")
			h.Set("Access-Control-Max-Age", "600")

			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
		}

		next.ServeHTTP(w, r)
	})
}

func reply(w http.ResponseWriter, status int, code, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": message, "code": code})
}

func health(w http.ResponseWriter, r *http.Request) {
	_, err := os.Stat(scanScript())

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":      "ok",
		"version":     version,
		"scan_script": map[bool]string{true: "present", false: "missing"}[err == nil],
	})
}

// scanScript sits beside the executable, which is where the installer puts
// it and the only place we can rely on.
func scanScript() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "scan.ps1")
}

func scan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		reply(w, http.StatusMethodNotAllowed, "method_not_allowed", "Use POST for /scan.")
		return
	}

	script := scanScript()
	if _, err := os.Stat(script); err != nil {
		reply(w, http.StatusInternalServerError, "scan_script_missing", "scan.ps1 is missing.")
		return
	}

	image, message, err := runScript(script)
	if err != nil {
		// "No scanner found" and friends mean the hardware is not there, which
		// is not a fault in this server.
		code, status := "scan_failed", http.StatusInternalServerError
		if strings.Contains(strings.ToLower(message), "scanner") {
			code, status = "scanner_not_connected", http.StatusServiceUnavailable
		}
		reply(w, status, code, message)
		return
	}

	// scan.ps1 already checks this, but a BMP slipping through would be served
	// as image/jpeg and look like a corrupt file to the caller.
	if len(image) < 2 || image[0] != 0xFF || image[1] != 0xD8 {
		reply(w, http.StatusInternalServerError, "not_a_jpeg", "The scan did not produce a JPEG.")
		return
	}

	w.Header().Set("Content-Type", "image/jpeg")
	w.Header().Set("Content-Length", fmt.Sprint(len(image)))
	w.Write(image)
}

// runScript scans to a temporary file and reads it back. WIA writes the whole
// image before anything can be read from it, so a file costs nothing and
// gives a size to check.
func runScript(script string) ([]byte, string, error) {
	out, err := os.CreateTemp(os.TempDir(), "scan-*.jpg")
	if err != nil {
		return nil, "Could not create a temporary file.", err
	}
	path := out.Name()
	out.Close()
	defer os.Remove(path)

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "powershell.exe",
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", script, "-OutputPath", path)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true} // no console window per scan

	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return nil, "The scan did not finish in 1 minute. The scanner may be stuck.", err
		}
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, message, err
	}

	image, err := os.ReadFile(path)
	if err != nil {
		return nil, "The scan produced no file.", err
	}
	return image, "", nil
}
