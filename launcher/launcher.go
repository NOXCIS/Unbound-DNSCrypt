package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start dnscrypt-proxy
	dnscryptCmd := exec.CommandContext(ctx, "/usr/local/bin/dnscrypt-proxy", "-config", "/config/dnscrypt-proxy.toml")
	dnscryptCmd.Stdout = os.Stdout
	dnscryptCmd.Stderr = os.Stderr
	if err := dnscryptCmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start dnscrypt-proxy: %v\n", err)
		os.Exit(1)
	}

	// Start unbound
	unboundCmd := exec.CommandContext(ctx, "/usr/sbin/unbound", "-c", "/etc/unbound/unbound.conf", "-d")
	unboundCmd.Stdout = os.Stdout
	unboundCmd.Stderr = os.Stderr
	if err := unboundCmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to start unbound: %v\n", err)
		dnscryptCmd.Process.Kill()
		os.Exit(1)
	}

	// Wait for termination signals
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Monitor processes
	done := make(chan error, 2)
	go func() {
		done <- dnscryptCmd.Wait()
	}()
	go func() {
		done <- unboundCmd.Wait()
	}()

	// Wait for signal or process exit
	select {
	case sig := <-sigChan:
		fmt.Fprintf(os.Stderr, "Received signal: %v, shutting down...\n", sig)
		cancel()
		dnscryptCmd.Process.Kill()
		unboundCmd.Process.Kill()
	case err := <-done:
		if err != nil {
			fmt.Fprintf(os.Stderr, "Process exited with error: %v, shutting down...\n", err)
		}
		cancel()
		dnscryptCmd.Process.Kill()
		unboundCmd.Process.Kill()
	}

	// Wait for both to finish
	dnscryptCmd.Wait()
	unboundCmd.Wait()
}
