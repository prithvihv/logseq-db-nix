package main

import (
	"fmt"
	"os"
	"strings"
)

// loadAllowlist combines ids given on the command line with the contents of
// the given files. In a file every line holds one id; blank lines are skipped
// and anything from a # to the end of the line is a comment, so entries can
// be annotated with who they belong to.
func loadAllowlist(ids []string, files []string) (map[string]struct{}, error) {
	users := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		if id = strings.TrimSpace(id); id != "" {
			users[id] = struct{}{}
		}
	}
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, fmt.Errorf("reading the allowlist: %w", err)
		}
		for _, line := range strings.Split(string(data), "\n") {
			if i := strings.IndexByte(line, '#'); i >= 0 {
				line = line[:i]
			}
			if line = strings.TrimSpace(line); line != "" {
				users[line] = struct{}{}
			}
		}
	}
	return users, nil
}
