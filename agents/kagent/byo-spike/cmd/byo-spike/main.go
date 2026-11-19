package main

import (
	"cmp"
	"context"
	"fmt"
	"log/slog"
	"os"

	a2atype "github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/kagent-dev/kagent/go/adk/pkg/a2a"
	"github.com/kagent-dev/kagent/go/adk/pkg/agent"
	"github.com/kagent-dev/kagent/go/adk/pkg/app"
	"github.com/kagent-dev/kagent/go/adk/pkg/config"
	kagentsession "github.com/kagent-dev/kagent/go/adk/pkg/session"
	"github.com/kagent-dev/kagent/go/pkg/logging"
	"google.golang.org/adk/v2/runner"
)

func run() error {
	ctx := context.Background()
	if err := config.MaterializeFromBootstrap(ctx, "/config"); err != nil {
		return fmt.Errorf("materialize bootstrap configuration: %w", err)
	}

	agentConfig, err := config.LoadAgentConfig("/config/config.json")
	if err != nil {
		return fmt.Errorf("load agent configuration: %w", err)
	}
	runtime := config.ProcessConfig(agentConfig)

	logger, err := logging.New(os.Stderr, cmp.Or(runtime.LogLevel, "info"))
	if err != nil {
		return fmt.Errorf("create logger: %w", err)
	}
	slog.SetDefault(logger)
	ctx = logging.IntoContext(ctx, logger)

	name := cmp.Or(runtime.Name, "byo-compatibility-probe")
	rootAgent, err := agent.CreateGoogleADKAgent(ctx, agentConfig, name, nil)
	if err != nil {
		return fmt.Errorf("create ADK agent: %w", err)
	}

	sessionService, err := kagentsession.NewService(agentConfig.GetAgent().GetSessionDbUrl())
	if err != nil {
		return fmt.Errorf("open durable session store: %w", err)
	}
	if sessionService == nil {
		return fmt.Errorf("durable session store requires session_db_url")
	}
	executor, err := a2a.NewKAgentExecutor(a2a.KAgentExecutorConfig{
		RunnerConfig: runner.Config{
			AppName:        name,
			Agent:          rootAgent,
			SessionService: sessionService,
		},
		SessionService: sessionService,
		Stream:         true,
		AppName:        name,
		Logger:         logger,
		AgentName:      name,
	})
	if err != nil {
		return fmt.Errorf("create A2A executor: %w", err)
	}

	application, err := app.New(app.AppConfig{
		ControlPlaneURL:  runtime.ControlPlaneUrl,
		MaxContentLength: runtime.MaxContentLength,
		AgentCard: a2atype.AgentCard{
			Name:        name,
			Description: "Exercises kagent BYO bootstrap, gRPC, model, MCP, and session integration.",
			Version:     "0.1.0",
			SupportedInterfaces: []*a2atype.AgentInterface{
				a2atype.NewAgentInterface("http://localhost:80", a2atype.TransportProtocolGRPC),
			},
			Capabilities:       a2atype.AgentCapabilities{Streaming: true},
			DefaultInputModes:  []string{"text/plain"},
			DefaultOutputModes: []string{"text/plain"},
			Skills: []a2atype.AgentSkill{{
				ID:          "byo-compatibility-probe",
				Name:        "BYO compatibility probe",
				Description: "Uses the configured product catalog and preserves a conversation across turns.",
			}},
		},
		Port:    fmt.Sprint(cmp.Or(runtime.GetPort(), 80)),
		AppName: name,
		Logger:  logger,
		Agent:   rootAgent,
	}, executor)
	if err != nil {
		return fmt.Errorf("create kagent A2A application: %w", err)
	}
	return application.Run()
}

func main() {
	if err := run(); err != nil {
		slog.Error("BYO compatibility probe stopped", "error", err)
		os.Exit(1)
	}
}
