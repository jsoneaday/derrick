package crawler

import (
	"net"
	"net/url"
	"strings"
)

func IsHTTP(u *url.URL) bool {
	scheme := strings.ToLower(u.Scheme)
	return scheme == "http" || scheme == "https"
}

func NormalizeURL(u *url.URL) *url.URL {
	if u == nil {
		return u
	}
	clone := *u
	clone.Scheme = strings.ToLower(clone.Scheme)
	clone.Host = strings.ToLower(clone.Host)
	clone.Fragment = ""
	if clone.Path == "" {
		clone.Path = "/"
	}
	if clone.Port() != "" {
		if (clone.Scheme == "http" && clone.Port() == "80") ||
			(clone.Scheme == "https" && clone.Port() == "443") {
			clone.Host = clone.Hostname()
		}
	}
	return &clone
}

func URLKey(u *url.URL) string {
	return NormalizeURL(u).String()
}

func ParseStartURL(raw string) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return nil, err
	}
	if !IsHTTP(u) {
		return nil, errInvalidStartURL
	}
	host := strings.ToLower(strings.TrimSpace(u.Hostname()))
	if host == "" {
		return nil, errInvalidStartURL
	}
	if u.User != nil {
		return nil, errInvalidStartURL
	}
	return NormalizeURL(u), nil
}

func ResolvedAllowedHosts(startHost string, explicit []string) map[string]bool {
	hosts := map[string]bool{strings.ToLower(startHost): true}
	for _, h := range explicit {
		n := strings.ToLower(strings.TrimSpace(h))
		if n != "" {
			hosts[n] = true
		}
	}
	return hosts
}

func HostAllowed(hosts map[string]bool, host string) bool {
	return hosts[strings.ToLower(strings.TrimSpace(host))]
}

func IsPrivateHost(host string) bool {
	host = strings.TrimSpace(strings.ToLower(host))
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast()
}

var errInvalidStartURL = validationError("start_url must be an http or https URL without embedded credentials.")

type validationError string

func (e validationError) Error() string { return string(e) }
