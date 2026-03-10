package main

import (
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/actions/scaleset"
)

type Config struct {
	RegistrationURL string
	MaxRunners      int
	MinRunners      int
	ScaleSetName    string
	Labels          []string
	RunnerGroup     string
	GitHubApp       scaleset.GitHubAppAuth
	Token           string
	RunnerDir       string
	LogLevel        string
	LogFormat       string
}

func (c *Config) defaults() {
	if c.RunnerGroup == "" {
		c.RunnerGroup = scaleset.DefaultRunnerGroup
	}
	if c.RunnerDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			home = "."
		}
		c.RunnerDir = filepath.Join(home, "actions-runner")
	}
}

func (c *Config) Validate() error {
	c.defaults()

	if _, err := url.ParseRequestURI(c.RegistrationURL); err != nil {
		return fmt.Errorf("invalid registration URL: %w (should be e.g. 'https://github.com/org' or 'https://github.com/org/repo')", err)
	}

	appError := c.GitHubApp.Validate()
	if c.Token == "" && appError != nil {
		return fmt.Errorf("no credentials provided: either GitHub App (client id, installation id, and private key) or a Personal Access Token are required")
	}

	if c.ScaleSetName == "" {
		return fmt.Errorf("scale set name is required")
	}

	for i, label := range c.Labels {
		if strings.TrimSpace(label) == "" {
			return fmt.Errorf("label at index %d is empty", i)
		}
	}

	if c.MaxRunners < c.MinRunners {
		return fmt.Errorf("max-runners (%d) cannot be less than min-runners (%d)", c.MaxRunners, c.MinRunners)
	}

	runScript := filepath.Join(c.RunnerDir, "run.sh")
	if _, err := os.Stat(runScript); os.IsNotExist(err) {
		return fmt.Errorf("runner binary not found at %s — run setup.sh first or set --runner-dir", runScript)
	}

	// If private key looks like a file path, read its contents
	if c.GitHubApp.PrivateKey != "" && !strings.HasPrefix(c.GitHubApp.PrivateKey, "-----") {
		data, err := os.ReadFile(c.GitHubApp.PrivateKey)
		if err != nil {
			return fmt.Errorf("failed to read private key file %s: %w", c.GitHubApp.PrivateKey, err)
		}
		c.GitHubApp.PrivateKey = string(data)
	}

	return nil
}

func systemInfo(scaleSetID int) scaleset.SystemInfo {
	return scaleset.SystemInfo{
		System:     "macos-scaleset",
		Subsystem:  "native-runner",
		CommitSHA:  "NA",
		Version:    "0.1.0",
		ScaleSetID: scaleSetID,
	}
}

func (c *Config) ScalesetClient() (*scaleset.Client, error) {
	if err := c.GitHubApp.Validate(); err == nil {
		return scaleset.NewClientWithGitHubApp(
			scaleset.ClientWithGitHubAppConfig{
				GitHubConfigURL: c.RegistrationURL,
				GitHubAppAuth:   c.GitHubApp,
				SystemInfo:      systemInfo(0),
			},
		)
	}

	return scaleset.NewClientWithPersonalAccessToken(
		scaleset.NewClientWithPersonalAccessTokenConfig{
			GitHubConfigURL:     c.RegistrationURL,
			PersonalAccessToken: c.Token,
			SystemInfo:          systemInfo(0),
		},
	)
}

func (c *Config) Logger() *slog.Logger {
	var lvl slog.Level
	switch strings.ToLower(c.LogLevel) {
	case "debug":
		lvl = slog.LevelDebug
	case "warn":
		lvl = slog.LevelWarn
	case "error":
		lvl = slog.LevelError
	default:
		lvl = slog.LevelInfo
	}

	switch c.LogFormat {
	case "json":
		return slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
			AddSource: true,
			Level:     lvl,
		}))
	case "text":
		return slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
			AddSource: true,
			Level:     lvl,
		}))
	default:
		return slog.New(slog.DiscardHandler)
	}
}

func (c *Config) BuildLabels() []scaleset.Label {
	if len(c.Labels) > 0 {
		labels := make([]scaleset.Label, len(c.Labels))
		for i, name := range c.Labels {
			labels[i] = scaleset.Label{Name: strings.TrimSpace(name)}
		}
		return labels
	}
	return []scaleset.Label{{Name: c.ScaleSetName}}
}
