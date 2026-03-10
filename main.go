package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
	"github.com/spf13/cobra"
)

func init() {
	flags := cmd.Flags()
	flags.StringVar(&cfg.RegistrationURL, "url", "", "REQUIRED: GitHub org or repo URL (e.g. https://github.com/org or https://github.com/org/repo)")
	flags.StringVar(&cfg.ScaleSetName, "name", "", "REQUIRED: Name of your scale set (also used as runs-on label)")
	flags.IntVar(&cfg.MaxRunners, "max-runners", 4, "Maximum number of concurrent runners")
	flags.IntVar(&cfg.MinRunners, "min-runners", 0, "Minimum number of idle runners to keep warm")
	flags.StringSliceVar(&cfg.Labels, "labels", nil, "Labels for workflow targeting (comma-separated or repeated). Defaults to --name if not provided.")
	flags.StringVar(&cfg.RunnerGroup, "runner-group", scaleset.DefaultRunnerGroup, "Name of the runner group")
	flags.StringVar(&cfg.GitHubApp.ClientID, "app-client-id", "", "GitHub App client ID")
	flags.Int64Var(&cfg.GitHubApp.InstallationID, "app-installation-id", 0, "GitHub App installation ID")
	flags.StringVar(&cfg.GitHubApp.PrivateKey, "app-private-key", "", "GitHub App private key (PEM contents or path to .pem file)")
	flags.StringVar(&cfg.Token, "token", "", "Personal access token (alternative to GitHub App, not recommended)")
	flags.StringVar(&cfg.RunnerDir, "runner-dir", "", "Path to the extracted GitHub Actions runner directory (default: ~/actions-runner)")
	flags.StringVar(&cfg.LogLevel, "log-level", "info", "Logging level (debug, info, warn, error)")
	flags.StringVar(&cfg.LogFormat, "log-format", "text", "Logging format (text, json)")

	_ = cmd.MarkFlagRequired("url")
	_ = cmd.MarkFlagRequired("name")
}

func main() {
	if err := cmd.Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, c Config) error {
	if err := c.Validate(); err != nil {
		return fmt.Errorf("configuration validation failed: %w", err)
	}

	logger := c.Logger()

	scalesetClient, err := c.ScalesetClient()
	if err != nil {
		return fmt.Errorf("failed to create scaleset client: %w", err)
	}

	var runnerGroupID int
	switch c.RunnerGroup {
	case scaleset.DefaultRunnerGroup:
		runnerGroupID = 1
	default:
		runnerGroup, err := scalesetClient.GetRunnerGroupByName(ctx, c.RunnerGroup)
		if err != nil {
			return fmt.Errorf("failed to get runner group ID: %w", err)
		}
		runnerGroupID = runnerGroup.ID
	}

	scaleSet, err := scalesetClient.CreateRunnerScaleSet(ctx, &scaleset.RunnerScaleSet{
		Name:          c.ScaleSetName,
		RunnerGroupID: runnerGroupID,
		Labels:        c.BuildLabels(),
		RunnerSetting: scaleset.RunnerSetting{
			DisableUpdate: true,
		},
	})
	if err != nil {
		return fmt.Errorf("failed to create runner scale set: %w", err)
	}

	scalesetClient.SetSystemInfo(systemInfo(scaleSet.ID))

	defer func() {
		logger.Info("Deleting runner scale set", slog.Int("scaleSetID", scaleSet.ID))
		if err := scalesetClient.DeleteRunnerScaleSet(context.WithoutCancel(ctx), scaleSet.ID); err != nil {
			logger.Error("Failed to delete runner scale set",
				slog.Int("scaleSetID", scaleSet.ID),
				slog.String("error", err.Error()),
			)
		}
	}()

	hostname, err := os.Hostname()
	if err != nil {
		hostname = uuid.NewString()
		logger.Info("Failed to get hostname, fallback to uuid", "uuid", hostname, "error", err)
	}

	sessionClient, err := scalesetClient.MessageSessionClient(ctx, scaleSet.ID, hostname)
	if err != nil {
		return fmt.Errorf("failed to create message session client: %w", err)
	}
	defer sessionClient.Close(context.Background())

	logger.Info("Initializing listener")
	l, err := listener.New(sessionClient, listener.Config{
		ScaleSetID: scaleSet.ID,
		MaxRunners: c.MaxRunners,
		Logger:     logger.WithGroup("listener"),
	})
	if err != nil {
		return fmt.Errorf("failed to create listener: %w", err)
	}

	sc := &Scaler{
		logger: logger.WithGroup("scaler"),
		runners: runnerState{
			idle: make(map[string]*runnerProcess),
			busy: make(map[string]*runnerProcess),
		},
		runnerDir:      c.RunnerDir,
		minRunners:     c.MinRunners,
		maxRunners:     c.MaxRunners,
		scalesetClient: scalesetClient,
		scaleSetID:     scaleSet.ID,
	}
	defer sc.shutdown(context.WithoutCancel(ctx))

	logger.Info("Starting listener",
		slog.String("scaleSet", scaleSet.Name),
		slog.Int("scaleSetID", scaleSet.ID),
		slog.Int("maxRunners", c.MaxRunners),
		slog.Int("minRunners", c.MinRunners),
		slog.String("runnerDir", c.RunnerDir),
	)

	if err := l.Run(ctx, sc); !errors.Is(err, context.Canceled) {
		return fmt.Errorf("listener run failed: %w", err)
	}
	return nil
}

var cfg Config

var cmd = &cobra.Command{
	Use:   "actions-scaling",
	Short: "Autoscaling GitHub Actions runners on native macOS",
	Long: `A lightweight autoscaler for GitHub Actions self-hosted runners on macOS.
Uses the actions/scaleset Go client to poll for job demand and spawn
ephemeral runner processes via JIT configs. Designed for Apple Silicon
Macs (M2+) running Xcode/iOS/macOS builds.`,
	RunE: func(cmd *cobra.Command, args []string) error {
		ctx, cancel := signal.NotifyContext(cmd.Context(), os.Interrupt)
		defer cancel()

		if err := cfg.Validate(); err != nil {
			return fmt.Errorf("invalid configuration: %w", err)
		}

		return run(ctx, cfg)
	},
}
