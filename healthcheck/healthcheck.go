package main

import (
	"context"
	"net"
	"os"
	"time"
)

func main() {
	// Check unbound on port 53
	unboundOK := checkDNS("127.0.0.1:53")
	
	// Check dnscrypt-proxy on port 5053
	dnscryptOK := checkDNS("127.0.0.1:5053")

	if !unboundOK || !dnscryptOK {
		os.Exit(1)
	}
	os.Exit(0)
}

func checkDNS(addr string) bool {
	resolver := &net.Resolver{
		PreferGo:     true,
		StrictErrors: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return net.DialTimeout("udp", addr, 2*time.Second)
		},
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	_, err := resolver.LookupHost(ctx, "cloudflare.com")
	return err == nil
}

