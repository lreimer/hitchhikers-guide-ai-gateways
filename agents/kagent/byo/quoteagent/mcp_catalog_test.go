package quoteagent

import (
	"context"
	"encoding/json"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	configv1 "github.com/kagent-dev/kagent/go/api/gen/kagent/config/v1"
	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/session"
	"google.golang.org/adk/v2/tool"
	"google.golang.org/genai"
)

func TestNewMCPCatalogRequiresAnIsolatedCatalogBinding(t *testing.T) {
	oneTool := func(name string, requireApproval bool) *configv1.ADKHTTPMCPServerConfig {
		return &configv1.ADKHTTPMCPServerConfig{
			Params:          &configv1.ADKHTTPConnectionParams{Url: "http://agentgateway/mcp"},
			Tools:           []string{name},
			RequireApproval: requireApproval,
		}
	}
	for _, test := range []struct {
		name    string
		config  *configv1.ADKAgentConfig
		wantErr bool
	}{
		{name: "missing catalog tool", config: &configv1.ADKAgentConfig{}, wantErr: true},
		{
			name: "extra tool binding",
			config: &configv1.ADKAgentConfig{HttpTools: []*configv1.ADKHTTPMCPServerConfig{{
				Params: &configv1.ADKHTTPConnectionParams{Url: "http://agentgateway/mcp"},
				Tools:  []string{catalogToolName, "catalog_lookup_internal_note"},
			}}},
			wantErr: true,
		},
		{
			name: "approval binding",
			config: &configv1.ADKAgentConfig{
				HttpTools: []*configv1.ADKHTTPMCPServerConfig{oneTool(catalogToolName, true)},
			},
			wantErr: true,
		},
		{
			name: "duplicate catalog bindings",
			config: &configv1.ADKAgentConfig{
				HttpTools: []*configv1.ADKHTTPMCPServerConfig{
					oneTool(catalogToolName, false),
					oneTool(catalogToolName, false),
				},
			},
			wantErr: true,
		},
		{
			name: "single catalog binding",
			config: &configv1.ADKAgentConfig{
				HttpTools: []*configv1.ADKHTTPMCPServerConfig{oneTool(catalogToolName, false)},
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := NewMCPCatalog(context.Background(), test.config)
			if (err != nil) != test.wantErr {
				t.Fatalf("NewMCPCatalog() error = %v, wantErr %t", err, test.wantErr)
			}
		})
	}
}

func TestParseProductConvertsCatalogPriceToIntegerCents(t *testing.T) {
	product, err := parseProduct(map[string]any{
		"product_id": "star-widget",
		"name":       "Star Widget",
		"price":      float64(12.5),
	}, "star-widget")
	if err != nil {
		t.Fatal(err)
	}
	if product.Name != "Star Widget" || product.UnitPriceCents != 1250 {
		t.Fatalf("parsed product = %#v; want Star Widget at 1250 cents", product)
	}
}

func TestPriceToCentsRejectsInvalidOrInexactPrices(t *testing.T) {
	for _, value := range []any{
		"12.345",
		json.Number("-1"),
		"92233720368547758.08",
		struct{}{},
	} {
		if _, err := priceToCents(value); err == nil {
			t.Errorf("priceToCents(%v) succeeded; want an error", value)
		}
	}
	if got, err := priceToCents(json.Number("24.00")); err != nil || got != byo.Cents(2400) {
		t.Fatalf("priceToCents(24.00) = %d, %v; want 2400 cents", got, err)
	}
}

func TestCatalogDiscoveryWaiterHonorsCancellation(t *testing.T) {
	lookupTool := &catalogToolDouble{}
	toolset := &blockingToolset{
		started: make(chan struct{}),
		release: make(chan struct{}),
		lookup:  lookupTool,
	}
	catalog := &mcpCatalog{toolset: toolset}

	firstContext, cancelFirst := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelFirst()
	firstResult := make(chan error, 1)
	go func() {
		_, err := catalog.Lookup(newToolContext(firstContext), "star-widget")
		firstResult <- err
	}()
	select {
	case <-toolset.started:
	case <-time.After(time.Second):
		t.Fatal("first lookup did not start tool discovery")
	}

	waiterStarted := make(chan struct{})
	secondBase, cancelSecond := context.WithCancel(context.Background())
	secondContext := &discoveryWaitContext{Context: secondBase, doneObserved: waiterStarted}
	secondResult := make(chan error, 1)
	go func() {
		_, err := catalog.Lookup(newToolContext(secondContext), "star-widget")
		secondResult <- err
	}()
	select {
	case <-waiterStarted:
	case <-time.After(time.Second):
		close(toolset.release)
		<-firstResult
		t.Fatal("second lookup did not wait for the in-flight discovery")
	}
	cancelSecond()

	select {
	case err := <-secondResult:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled waiter error = %v, want context.Canceled", err)
		}
	case <-time.After(time.Second):
		close(toolset.release)
		<-firstResult
		t.Fatal("canceled waiter remained blocked on tool discovery")
	}

	close(toolset.release)
	if err := <-firstResult; err != nil {
		t.Fatalf("discovery owner lookup error = %v", err)
	}
	if got := toolset.calls.Load(); got != 1 {
		t.Fatalf("toolset discovery calls = %d, want 1", got)
	}
	if got := lookupTool.calls.Load(); got != 1 {
		t.Fatalf("catalog tool calls = %d, want only the discovery owner's call", got)
	}
}

type blockingToolset struct {
	started chan struct{}
	release chan struct{}
	lookup  tool.Tool
	once    sync.Once
	calls   atomic.Int32
}

func (s *blockingToolset) Name() string { return "blocking-test-toolset" }

func (s *blockingToolset) Tools(ctx agent.ReadonlyContext) ([]tool.Tool, error) {
	s.calls.Add(1)
	s.once.Do(func() { close(s.started) })
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-s.release:
		return []tool.Tool{s.lookup}, nil
	}
}

type catalogToolDouble struct {
	calls atomic.Int32
}

func (t *catalogToolDouble) Name() string        { return catalogToolName }
func (t *catalogToolDouble) Description() string { return "test catalog lookup" }
func (t *catalogToolDouble) IsLongRunning() bool { return false }

func (t *catalogToolDouble) Run(ctx agent.Context, _ any) (map[string]any, error) {
	t.calls.Add(1)
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return map[string]any{
		"output": map[string]any{
			"product_id": "star-widget",
			"name":       "Star Widget",
			"price":      float64(12.5),
		},
	}, nil
}

type discoveryWaitContext struct {
	context.Context
	doneObserved chan struct{}
	once         sync.Once
}

func (c *discoveryWaitContext) Done() <-chan struct{} {
	c.once.Do(func() { close(c.doneObserved) })
	return c.Context.Done()
}

type invocationContextStub struct {
	context.Context
}

func (c *invocationContextStub) Agent() agent.Agent          { return nil }
func (c *invocationContextStub) Artifacts() agent.Artifacts  { return nil }
func (c *invocationContextStub) Memory() agent.Memory        { return nil }
func (c *invocationContextStub) Session() session.Session    { return nil }
func (c *invocationContextStub) InvocationID() string        { return "test-invocation" }
func (c *invocationContextStub) Branch() string              { return "" }
func (c *invocationContextStub) IsolationScope() string      { return "" }
func (c *invocationContextStub) UserContent() *genai.Content { return nil }
func (c *invocationContextStub) RunConfig() *agent.RunConfig { return nil }
func (c *invocationContextStub) EndInvocation()              {}
func (c *invocationContextStub) Ended() bool                 { return false }
func (c *invocationContextStub) ResumedInput(string) (any, bool) {
	return nil, false
}
func (c *invocationContextStub) WithICDelta(*agent.InvocationContextDelta) agent.InvocationContext {
	return c
}
func (c *invocationContextStub) WithContext(ctx context.Context) agent.InvocationContext {
	return &invocationContextStub{Context: ctx}
}

func newToolContext(ctx context.Context) agent.Context {
	return agent.NewToolContext(&invocationContextStub{Context: ctx}, "test-call", nil, nil)
}
