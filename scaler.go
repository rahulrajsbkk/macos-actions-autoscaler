package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/actions/scaleset"
	"github.com/actions/scaleset/listener"
	"github.com/google/uuid"
)

type runnerProcess struct {
	cmd *exec.Cmd
	pid int
	// done is closed when the process exits
	done chan struct{}
}

type Scaler struct {
	runners        runnerState
	runnerDir      string
	scaleSetID     int
	scalesetClient *scaleset.Client
	minRunners     int
	maxRunners     int
	logger         *slog.Logger
}

func (s *Scaler) HandleDesiredRunnerCount(ctx context.Context, count int) (int, error) {
	currentCount := s.runners.count()
	targetRunnerCount := min(s.maxRunners, s.minRunners+count)

	switch {
	case targetRunnerCount == currentCount:
		return currentCount, nil

	case targetRunnerCount > currentCount:
		scaleUp := targetRunnerCount - currentCount
		s.logger.Info("Scaling up runners",
			slog.Int("currentCount", currentCount),
			slog.Int("desiredCount", targetRunnerCount),
			slog.Int("scaleUp", scaleUp),
		)

		for range scaleUp {
			if _, err := s.startRunner(ctx); err != nil {
				return 0, fmt.Errorf("failed to start runner: %w", err)
			}
		}

		return s.runners.count(), nil

	default:
		// Scale-down is handled passively: ephemeral runners exit after
		// their job completes, and HandleJobCompleted cleans them up.
		return currentCount, nil
	}
}

func (s *Scaler) HandleJobStarted(ctx context.Context, jobInfo *scaleset.JobStarted) error {
	s.logger.Info("Job started",
		slog.Int64("runnerRequestId", jobInfo.RunnerRequestID),
		slog.String("jobId", jobInfo.JobID),
		slog.String("runnerName", jobInfo.RunnerName),
	)
	s.runners.markBusy(jobInfo.RunnerName)
	return nil
}

func (s *Scaler) HandleJobCompleted(ctx context.Context, jobInfo *scaleset.JobCompleted) error {
	s.logger.Info("Job completed",
		slog.Int64("runnerRequestId", jobInfo.RunnerRequestID),
		slog.String("jobId", jobInfo.JobID),
		slog.String("result", jobInfo.Result),
		slog.String("runnerName", jobInfo.RunnerName),
	)

	rp := s.runners.markDone(jobInfo.RunnerName)
	if rp != nil && rp.cmd != nil && rp.cmd.Process != nil {
		// Wait for the process to fully exit (it should already be exiting
		// since the runner self-deregisters after one job)
		<-rp.done
	}

	return nil
}

func (s *Scaler) startRunner(ctx context.Context) (string, error) {
	name := fmt.Sprintf("runner-%s", uuid.NewString()[:8])

	jit, err := s.scalesetClient.GenerateJitRunnerConfig(
		ctx,
		&scaleset.RunnerScaleSetJitRunnerSetting{
			Name: name,
		},
		s.scaleSetID,
	)
	if err != nil {
		return "", fmt.Errorf("failed to generate JIT config: %w", err)
	}

	runScript := filepath.Join(s.runnerDir, "run.sh")
	cmd := exec.CommandContext(ctx, runScript)
	cmd.Dir = s.runnerDir
	cmd.Env = append(os.Environ(),
		fmt.Sprintf("ACTIONS_RUNNER_INPUT_JITCONFIG=%s", jit.EncodedJITConfig),
	)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return "", fmt.Errorf("failed to start runner process: %w", err)
	}

	rp := &runnerProcess{
		cmd:  cmd,
		pid:  cmd.Process.Pid,
		done: make(chan struct{}),
	}

	// Wait for process exit in background
	go func() {
		defer close(rp.done)
		if err := cmd.Wait(); err != nil {
			s.logger.Debug("Runner process exited",
				slog.String("name", name),
				slog.Int("pid", rp.pid),
				slog.String("error", err.Error()),
			)
		} else {
			s.logger.Info("Runner process exited cleanly",
				slog.String("name", name),
				slog.Int("pid", rp.pid),
			)
		}
	}()

	s.runners.addIdle(name, rp)
	s.logger.Info("Started runner process",
		slog.String("name", name),
		slog.Int("pid", rp.pid),
	)

	return name, nil
}

func (s *Scaler) shutdown(ctx context.Context) {
	s.logger.Info("Shutting down runners")
	s.runners.mu.Lock()
	defer s.runners.mu.Unlock()

	killRunner := func(name string, rp *runnerProcess) {
		if rp.cmd == nil || rp.cmd.Process == nil {
			return
		}
		s.logger.Info("Terminating runner",
			slog.String("name", name),
			slog.Int("pid", rp.pid),
		)
		// SIGTERM first for graceful shutdown
		_ = rp.cmd.Process.Signal(syscall.SIGTERM)
	}

	for name, rp := range s.runners.idle {
		killRunner(name, rp)
	}
	clear(s.runners.idle)

	for name, rp := range s.runners.busy {
		killRunner(name, rp)
	}
	clear(s.runners.busy)
}

var _ listener.Scaler = (*Scaler)(nil)

type runnerState struct {
	mu   sync.Mutex
	idle map[string]*runnerProcess
	busy map[string]*runnerProcess
}

func (r *runnerState) count() int {
	r.mu.Lock()
	count := len(r.idle) + len(r.busy)
	r.mu.Unlock()
	return count
}

func (r *runnerState) markBusy(name string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	rp, ok := r.idle[name]
	if !ok {
		return
	}
	delete(r.idle, name)
	r.busy[name] = rp
}

func (r *runnerState) markDone(name string) *runnerProcess {
	r.mu.Lock()
	defer r.mu.Unlock()

	if rp, ok := r.busy[name]; ok {
		delete(r.busy, name)
		return rp
	}
	if rp, ok := r.idle[name]; ok {
		delete(r.idle, name)
		return rp
	}
	return nil
}

func (r *runnerState) addIdle(name string, rp *runnerProcess) {
	r.mu.Lock()
	r.idle[name] = rp
	r.mu.Unlock()
}
