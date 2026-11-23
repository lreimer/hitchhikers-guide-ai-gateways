package quoteagent

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	a2atype "github.com/a2aproject/a2a-go/v2/a2a"
	"github.com/a2aproject/a2a-go/v2/a2asrv"
	kagentA2A "github.com/kagent-dev/kagent/go/adk/pkg/a2a"
	kagentSession "github.com/kagent-dev/kagent/go/adk/pkg/session"
	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/runner"
	"google.golang.org/adk/v2/session"
	"google.golang.org/genai"
)

const (
	testAppName = "quote-agent-test"
	testUserID  = "user"
)

type extractorFunc func(context.Context, string, byo.Draft) (Patch, error)

func (f extractorFunc) Extract(ctx context.Context, input string, draft byo.Draft, _ ClarificationContext) (Patch, error) {
	return f(ctx, input, draft)
}

type contextExtractorFunc func(context.Context, string, byo.Draft, ClarificationContext) (Patch, error)

func (f contextExtractorFunc) Extract(
	ctx context.Context,
	input string,
	draft byo.Draft,
	clarification ClarificationContext,
) (Patch, error) {
	return f(ctx, input, draft, clarification)
}

type catalogFake struct {
	mu       sync.Mutex
	products map[byo.ProductID]byo.Product
	calls    []byo.ProductID
	err      error
}

func (c *catalogFake) Lookup(ctx agent.Context, productID byo.ProductID) (byo.Product, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls = append(c.calls, productID)
	if err := ctx.Err(); err != nil {
		return byo.Product{}, err
	}
	if c.err != nil {
		return byo.Product{}, c.err
	}
	product, ok := c.products[productID]
	if !ok {
		return byo.Product{}, fmt.Errorf("%w: %q", byo.ErrUnknownProduct, productID)
	}
	return product, nil
}

func (c *catalogFake) callCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.calls)
}

func TestQuoteWorkflowRestoresDraftAndCalculatesDeterministically(t *testing.T) {
	firstQuantity := byo.Quantity(3)
	secondQuantity := byo.Quantity(2)
	updatedQuantity := byo.Quantity(1)
	budget := byo.Cents(8000)
	var seenDrafts []byo.Draft
	extractor := extractorFunc(func(_ context.Context, input string, draft byo.Draft) (Patch, error) {
		seenDrafts = append(seenDrafts, cloneDraft(draft))
		switch input {
		case "initial":
			return Patch{
				Positions: []PositionPatch{
					{ProductID: "star-widget", Quantity: &firstQuantity},
					{ProductID: "moon-gadget", Quantity: &secondQuantity},
				},
				BudgetCents: &budget,
			}, nil
		case "change":
			return Patch{Positions: []PositionPatch{{ProductID: "moon-gadget", Quantity: &updatedQuantity}}}, nil
		default:
			return Patch{}, fmt.Errorf("unexpected input %q", input)
		}
	})
	catalog := &catalogFake{products: testCatalog()}
	storagePath := filepath.Join(t.TempDir(), "sessions.db")

	firstService, err := kagentSession.NewLocalSessionService("sqlite:////" + strings.TrimPrefix(storagePath, "/"))
	if err != nil {
		t.Fatal(err)
	}
	firstRunner := newRunner(t, firstService, extractor, catalog, time.Second)
	createSession(t, firstService, "persistent-session")
	firstEvents := runTurn(t, firstRunner, "persistent-session", "initial")
	firstResponse := finalText(firstEvents)
	if !strings.Contains(firstResponse, "Total: $85.50") || !strings.Contains(firstResponse, "Over budget by $5.50") {
		t.Fatalf("initial response = %q; want exact total and over-budget status", firstResponse)
	}

	restoredService, err := kagentSession.NewLocalSessionService("sqlite:////" + strings.TrimPrefix(storagePath, "/"))
	if err != nil {
		t.Fatal(err)
	}
	restoredRunner := newRunner(t, restoredService, extractor, catalog, time.Second)
	secondEvents := runTurn(t, restoredRunner, "persistent-session", "change")
	secondResponse := finalText(secondEvents)
	if !strings.Contains(secondResponse, "Total: $61.50") || !strings.Contains(secondResponse, "Within budget; $18.50 remains") {
		t.Fatalf("follow-up response = %q; want exact total and remaining budget", secondResponse)
	}
	if len(seenDrafts) != 2 || len(seenDrafts[1].Positions) != 2 ||
		seenDrafts[1].Positions[0].ProductID != "star-widget" ||
		*seenDrafts[1].Positions[0].Quantity != 3 ||
		*seenDrafts[1].Positions[1].Quantity != 2 {
		t.Fatalf("restored draft passed to extractor = %#v; want both original positions before patch", seenDrafts)
	}
	if catalog.callCount() != 4 {
		t.Fatalf("catalog calls = %d, want 2 per completed quote", catalog.callCount())
	}
}

func TestQuoteWorkflowRestoresPendingClarificationAcrossSessions(t *testing.T) {
	starQuantity := byo.Quantity(3)
	moonQuantity := byo.Quantity(2)
	updatedQuantity := byo.Quantity(4)
	budget := byo.Cents(8000)
	placeholderIndex := 2
	var seenDrafts []byo.Draft
	var seenClarifications []ClarificationContext
	extractor := contextExtractorFunc(func(
		_ context.Context,
		input string,
		draft byo.Draft,
		clarification ClarificationContext,
	) (Patch, error) {
		seenDrafts = append(seenDrafts, cloneDraft(draft))
		seenClarifications = append(seenClarifications, clarification)
		switch input {
		case "initial":
			return Patch{
				Positions: []PositionPatch{
					{ProductID: "star-widget", Quantity: &starQuantity},
					{ProductID: "moon-gadget", Quantity: &moonQuantity},
				},
				BudgetCents: &budget,
			}, nil
		case "change quantity to four":
			return Patch{
				Positions: []PositionPatch{{Quantity: &updatedQuantity}},
				Question:  "Which product should I change to four?",
			}, nil
		case "Moon Gadget":
			if len(draft.Positions) != 3 || draft.Positions[2].ProductID != "" ||
				draft.Positions[2].Quantity == nil || *draft.Positions[2].Quantity != 4 {
				return Patch{}, fmt.Errorf("pending quantity was not retained: %#v", draft)
			}
			if clarification.UserRequest != "change quantity to four" ||
				clarification.Question != "Which product should I change to four?" {
				return Patch{}, fmt.Errorf("clarification context was not restored: %#v", clarification)
			}
			return Patch{Positions: []PositionPatch{{
				Index:     &placeholderIndex,
				ProductID: "moon-gadget",
			}}}, nil
		default:
			return Patch{}, fmt.Errorf("unexpected input %q", input)
		}
	})
	catalog := &catalogFake{products: testCatalog()}
	storagePath := filepath.Join(t.TempDir(), "clarification.db")
	firstService, err := kagentSession.NewLocalSessionService("sqlite:////" + strings.TrimPrefix(storagePath, "/"))
	if err != nil {
		t.Fatal(err)
	}
	firstRunner := newRunner(t, firstService, extractor, catalog, time.Second)
	createSession(t, firstService, "clarification-session")
	runTurn(t, firstRunner, "clarification-session", "initial")

	questionEvents := runTurn(t, firstRunner, "clarification-session", "change quantity to four")
	if got := finalText(questionEvents); got != "Which product should I change to four?" {
		t.Fatalf("clarification response = %q", got)
	}
	if catalog.callCount() != 2 {
		t.Fatalf("catalog calls before clarification is resolved = %d, want only the initial quote's 2 calls",
			catalog.callCount())
	}

	restoredService, err := kagentSession.NewLocalSessionService("sqlite:////" + strings.TrimPrefix(storagePath, "/"))
	if err != nil {
		t.Fatal(err)
	}
	restoredRunner := newRunner(t, restoredService, extractor, catalog, time.Second)
	resolvedEvents := runTurn(t, restoredRunner, "clarification-session", "Moon Gadget")
	response := finalText(resolvedEvents)
	if !strings.Contains(response, "Total: $133.50") || !strings.Contains(response, "Over budget by $53.50") {
		t.Fatalf("resolved response = %q; want the pending Moon Gadget quantity applied to the restored quote", response)
	}
	if catalog.callCount() != 4 {
		t.Fatalf("catalog calls after clarification = %d, want 2 more for the completed quote", catalog.callCount())
	}
	if len(seenDrafts) != 3 || seenClarifications[2].LatestReply != "" {
		t.Fatalf("restored drafts/clarifications = %#v / %#v", seenDrafts, seenClarifications)
	}
}

func TestQuoteWorkflowKeepsSessionsIsolatedAndAsksForMissingFields(t *testing.T) {
	one := byo.Quantity(1)
	extractor := extractorFunc(func(_ context.Context, input string, draft byo.Draft) (Patch, error) {
		if input != "partial" {
			return Patch{}, fmt.Errorf("unexpected input %q", input)
		}
		if len(draft.Positions) != 0 || draft.BudgetCents != nil {
			return Patch{}, fmt.Errorf("new session received prior draft: %#v", draft)
		}
		return Patch{Positions: []PositionPatch{{ProductID: "moon-gadget", Quantity: &one}}}, nil
	})
	catalog := &catalogFake{products: testCatalog()}
	service := session.InMemoryService()
	agentRunner := newRunner(t, service, extractor, catalog, time.Second)
	createSession(t, service, "first-session")
	createSession(t, service, "second-session")

	firstEvents := runTurn(t, agentRunner, "first-session", "partial")
	response := finalText(firstEvents)
	if !strings.Contains(response, "What is your budget in USD?") {
		t.Fatalf("incomplete response = %q; want a normal budget follow-up", response)
	}
	if strings.Contains(response, "Total:") || catalog.callCount() != 0 {
		t.Fatalf("incomplete draft must not be quoted or sent to the catalog: response=%q calls=%d",
			response, catalog.callCount())
	}

	secondEvents := runTurn(t, agentRunner, "second-session", "partial")
	if got := finalText(secondEvents); !strings.Contains(got, "What is your budget in USD?") {
		t.Fatalf("isolated session response = %q; want a budget follow-up", got)
	}
}

func TestQuoteWorkflowContinuesNormalFollowUpDialogue(t *testing.T) {
	one := byo.Quantity(1)
	budget := byo.Cents(8000)
	var seenDrafts []byo.Draft
	extractor := extractorFunc(func(_ context.Context, input string, draft byo.Draft) (Patch, error) {
		seenDrafts = append(seenDrafts, cloneDraft(draft))
		switch input {
		case "partial":
			return Patch{Positions: []PositionPatch{{ProductID: "moon-gadget", Quantity: &one}}}, nil
		case "budget":
			return Patch{BudgetCents: &budget}, nil
		default:
			return Patch{}, fmt.Errorf("unexpected input %q", input)
		}
	})
	catalog := &catalogFake{products: testCatalog()}
	service := session.InMemoryService()
	agentRunner := newRunner(t, service, extractor, catalog, time.Second)
	createSession(t, service, "dialogue-session")

	firstEvents := runTurn(t, agentRunner, "dialogue-session", "partial")
	if got := finalText(firstEvents); got != "What is your budget in USD?" {
		t.Fatalf("first response = %q; want a normal budget follow-up", got)
	}
	if catalog.callCount() != 0 {
		t.Fatalf("catalog calls before required detail = %d, want 0", catalog.callCount())
	}

	secondEvents := runTurn(t, agentRunner, "dialogue-session", "budget")
	if got := finalText(secondEvents); !strings.Contains(got, "Total: $24.00") ||
		!strings.Contains(got, "Within budget; $56.00 remains") {
		t.Fatalf("completed response = %q; want a deterministic quote after the follow-up", got)
	}
	if len(seenDrafts) != 2 || len(seenDrafts[1].Positions) != 1 ||
		seenDrafts[1].Positions[0].ProductID != "moon-gadget" ||
		seenDrafts[1].Positions[0].Quantity == nil ||
		*seenDrafts[1].Positions[0].Quantity != 1 {
		t.Fatalf("follow-up draft = %#v; want the saved Moon Gadget position", seenDrafts)
	}
}

func TestQuoteWorkflowAsksAboutAmbiguityWithoutCallingCatalog(t *testing.T) {
	extractor := extractorFunc(func(context.Context, string, byo.Draft) (Patch, error) {
		return Patch{Question: "Which Moon Gadget quantity do you mean?"}, nil
	})
	catalog := &catalogFake{products: testCatalog()}
	service := session.InMemoryService()
	agentRunner := newRunner(t, service, extractor, catalog, time.Second)
	createSession(t, service, "ambiguous-session")

	events := runTurn(t, agentRunner, "ambiguous-session", "ambiguous")
	if got := finalText(events); got != "Which Moon Gadget quantity do you mean?" {
		t.Fatalf("ambiguous response = %q; want the extractor's follow-up", got)
	}
	if catalog.callCount() != 0 {
		t.Fatalf("catalog calls for ambiguous request = %d, want 0", catalog.callCount())
	}
}

func TestApplyPatchDoesNotImplicitlyConsumeSamePatchPlaceholders(t *testing.T) {
	three := byo.Quantity(3)
	two := byo.Quantity(2)
	tests := []struct {
		name       string
		patch      Patch
		wantLen    int
		wantFirst  byo.Position
		wantSecond byo.Position
	}{
		{
			name: "quantity placeholder is not consumed by later product update",
			patch: Patch{
				Positions: []PositionPatch{
					{Quantity: &three},
					{ProductID: "moon-gadget", Quantity: &two},
				},
			},
			wantLen:    2,
			wantFirst:  byo.Position{Quantity: &three},
			wantSecond: byo.Position{ProductID: "moon-gadget", Quantity: &two},
		},
		{
			name: "multiple quantity placeholders remain distinct",
			patch: Patch{
				Positions: []PositionPatch{
					{Quantity: &three},
					{Quantity: &two},
				},
			},
			wantLen:    2,
			wantFirst:  byo.Position{Quantity: &three},
			wantSecond: byo.Position{Quantity: &two},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			updated, err := applyPatch(byo.Draft{}, test.patch)
			if err != nil {
				t.Fatalf("applyPatch error = %v", err)
			}
			if len(updated.Positions) != test.wantLen {
				t.Fatalf("positions = %#v, want len %d", updated.Positions, test.wantLen)
			}
			assertPosition(t, updated.Positions[0], test.wantFirst)
			assertPosition(t, updated.Positions[1], test.wantSecond)
		})
	}
}

func TestApplyPatchKeepsIndexedUpdatesStableUntilPatchCompletes(t *testing.T) {
	three := byo.Quantity(3)
	two := byo.Quantity(2)
	four := byo.Quantity(4)
	five := byo.Quantity(5)
	indexTwo := 2
	indexThree := 3
	updated, err := applyPatch(byo.Draft{
		Positions: []byo.Position{
			{ProductID: "star-widget", Quantity: &three},
			{ProductID: "moon-gadget", Quantity: &two},
			{Quantity: &four},
			{Quantity: &five},
		},
	}, Patch{
		Positions: []PositionPatch{
			{Index: &indexTwo, ProductID: "star-widget"},
			{Index: &indexThree, ProductID: "moon-gadget"},
		},
	})
	if err != nil {
		t.Fatalf("applyPatch error = %v", err)
	}
	if len(updated.Positions) != 2 {
		t.Fatalf("positions = %#v, want two resolved product positions", updated.Positions)
	}
	assertPosition(t, updated.Positions[0], byo.Position{ProductID: "star-widget", Quantity: &four})
	assertPosition(t, updated.Positions[1], byo.Position{ProductID: "moon-gadget", Quantity: &five})
}

func TestApplyPatchMatchesProductsBeforeImplicitPlaceholderResolution(t *testing.T) {
	three := byo.Quantity(3)
	four := byo.Quantity(4)
	one := byo.Quantity(1)
	placeholderIndex := 1
	updated, err := applyPatch(byo.Draft{
		Positions: []byo.Position{
			{ProductID: "star-widget", Quantity: &three},
			{Quantity: &four},
		},
	}, Patch{
		Positions: []PositionPatch{{ProductID: "star-widget", Quantity: &one}},
	})
	if err != nil {
		t.Fatalf("applyPatch error = %v", err)
	}
	if len(updated.Positions) != 2 {
		t.Fatalf("positions = %#v, want unresolved placeholder retained", updated.Positions)
	}
	assertPosition(t, updated.Positions[0], byo.Position{ProductID: "star-widget", Quantity: &one})
	assertPosition(t, updated.Positions[1], byo.Position{Quantity: &four})

	resolved, err := applyPatch(byo.Draft{
		Positions: []byo.Position{
			{ProductID: "star-widget", Quantity: &three},
			{Quantity: &four},
		},
	}, Patch{
		Positions: []PositionPatch{{Index: &placeholderIndex, ProductID: "star-widget"}},
	})
	if err != nil {
		t.Fatalf("applyPatch error for explicit placeholder resolution = %v", err)
	}
	if len(resolved.Positions) != 1 {
		t.Fatalf("positions = %#v, want merged explicit placeholder", resolved.Positions)
	}
	assertPosition(t, resolved.Positions[0], byo.Position{ProductID: "star-widget", Quantity: &four})
}

func TestQuoteWorkflowPropagatesModelAndCatalogFailures(t *testing.T) {
	rateLimit := errors.New("HTTP 429: rate limit")
	quantity := byo.Quantity(1)
	budget := byo.Cents(8000)
	for _, test := range []struct {
		name      string
		extractor Extractor
		catalog   *catalogFake
		wantErr   error
		wantCalls int
	}{
		{
			name: "model rate limit",
			extractor: extractorFunc(func(context.Context, string, byo.Draft) (Patch, error) {
				return Patch{}, rateLimit
			}),
			catalog: &catalogFake{products: testCatalog()},
			wantErr: rateLimit,
		},
		{
			name: "catalog failure",
			extractor: extractorFunc(func(context.Context, string, byo.Draft) (Patch, error) {
				return Patch{
					Positions:   []PositionPatch{{ProductID: "star-widget", Quantity: &quantity}},
					BudgetCents: &budget,
				}, nil
			}),
			catalog:   &catalogFake{err: rateLimit},
			wantErr:   rateLimit,
			wantCalls: 1,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			service := session.InMemoryService()
			agentRunner := newRunner(t, service, test.extractor, test.catalog, time.Second)
			createSession(t, service, "error-session")
			_, gotErr := runTurnWithError(t, agentRunner, "error-session", "request")
			if !errors.Is(gotErr, test.wantErr) {
				t.Fatalf("workflow error = %v, want %v", gotErr, test.wantErr)
			}
			if got := test.catalog.callCount(); got != test.wantCalls {
				t.Fatalf("catalog calls = %d, want %d", got, test.wantCalls)
			}
		})
	}
}

func TestQuoteWorkflowStopsAfterModelAndCatalogTimeouts(t *testing.T) {
	quantity := byo.Quantity(1)
	budget := byo.Cents(8000)
	t.Run("model timeout", func(t *testing.T) {
		catalog := &catalogFake{products: testCatalog()}
		extractor := extractorFunc(func(ctx context.Context, _ string, _ byo.Draft) (Patch, error) {
			<-ctx.Done()
			return Patch{}, ctx.Err()
		})
		service := session.InMemoryService()
		agentRunner := newRunner(t, service, extractor, catalog, 10*time.Millisecond)
		createSession(t, service, "model-timeout-session")

		_, gotErr := runTurnWithError(t, agentRunner, "model-timeout-session", "request")
		if !errors.Is(gotErr, context.DeadlineExceeded) {
			t.Fatalf("workflow error = %v, want context.DeadlineExceeded", gotErr)
		}
		if catalog.callCount() != 0 {
			t.Fatalf("catalog calls after model timeout = %d, want 0", catalog.callCount())
		}
	})

	t.Run("catalog timeout", func(t *testing.T) {
		catalogCalls := 0
		catalog := catalogFunc(func(ctx agent.Context, _ byo.ProductID) (byo.Product, error) {
			catalogCalls++
			<-ctx.Done()
			return byo.Product{}, ctx.Err()
		})
		extractor := extractorFunc(func(context.Context, string, byo.Draft) (Patch, error) {
			return Patch{
				Positions: []PositionPatch{
					{ProductID: "star-widget", Quantity: &quantity},
					{ProductID: "moon-gadget", Quantity: &quantity},
				},
				BudgetCents: &budget,
			}, nil
		})
		service := session.InMemoryService()
		rootAgent, err := New(Config{
			Extractor:   extractor,
			Catalog:     catalog,
			CallTimeout: 10 * time.Millisecond,
		})
		if err != nil {
			t.Fatal(err)
		}
		agentRunner, err := runner.New(runner.Config{
			AppName:        testAppName,
			Agent:          rootAgent,
			SessionService: service,
		})
		if err != nil {
			t.Fatal(err)
		}
		createSession(t, service, "catalog-timeout-session")

		_, gotErr := runTurnWithError(t, agentRunner, "catalog-timeout-session", "request")
		if !errors.Is(gotErr, context.DeadlineExceeded) {
			t.Fatalf("workflow error = %v, want context.DeadlineExceeded", gotErr)
		}
		if catalogCalls != 1 {
			t.Fatalf("catalog calls after first lookup timeout = %d, want 1", catalogCalls)
		}
	})
}

func TestQuoteWorkflowStopsBeforeCatalogAfterCancellation(t *testing.T) {
	quantity := byo.Quantity(1)
	budget := byo.Cents(8000)
	catalog := &catalogFake{products: testCatalog()}
	extractor := extractorFunc(func(ctx context.Context, _ string, _ byo.Draft) (Patch, error) {
		cancel := ctx.Value(cancelContextKey{}).(context.CancelFunc)
		cancel()
		return Patch{
			Positions:   []PositionPatch{{ProductID: "star-widget", Quantity: &quantity}},
			BudgetCents: &budget,
		}, nil
	})
	service := session.InMemoryService()
	agentRunner := newRunner(t, service, extractor, catalog, time.Second)
	createSession(t, service, "cancel-session")
	parent, cancel := context.WithCancel(context.Background())
	ctx := context.WithValue(parent, cancelContextKey{}, cancel)
	defer cancel()

	_, gotErr := runTurnWithContext(t, ctx, agentRunner, "cancel-session", "request")
	if !errors.Is(gotErr, context.Canceled) {
		t.Fatalf("workflow error = %v, want context.Canceled", gotErr)
	}
	if got := catalog.callCount(); got != 0 {
		t.Fatalf("catalog calls after cancellation = %d, want 0", got)
	}
}

func TestKAgentExecutorKeepsTaskAndContextIDsOnProgressAndTerminalEvents(t *testing.T) {
	quantity := byo.Quantity(1)
	budget := byo.Cents(8000)
	rootAgent, err := New(Config{
		Extractor: extractorFunc(func(context.Context, string, byo.Draft) (Patch, error) {
			return Patch{
				Positions:   []PositionPatch{{ProductID: "star-widget", Quantity: &quantity}},
				BudgetCents: &budget,
			}, nil
		}),
		Catalog: &catalogFake{products: testCatalog()},
	})
	if err != nil {
		t.Fatal(err)
	}
	service := session.InMemoryService()
	logger := slog.New(slog.DiscardHandler)
	executor, err := kagentA2A.NewKAgentExecutor(kagentA2A.KAgentExecutorConfig{
		RunnerConfig: runner.Config{
			AppName:        testAppName,
			Agent:          rootAgent,
			SessionService: service,
		},
		SessionService: service,
		Stream:         true,
		AppName:        testAppName,
		Logger:         logger,
		AgentName:      AgentName,
	})
	if err != nil {
		t.Fatal(err)
	}
	request := &a2asrv.ExecutorContext{
		TaskID:    "quote-task",
		ContextID: "quote-context",
		Message:   a2atype.NewMessage(a2atype.MessageRoleUser, a2atype.NewTextPart("request")),
	}
	eventCount := 0
	for event, err := range executor.Execute(context.Background(), request) {
		if err != nil {
			t.Fatalf("A2A execute: %v", err)
		}
		if event == nil {
			continue
		}
		eventCount++
		info := event.TaskInfo()
		if info.TaskID != request.TaskID || info.ContextID != request.ContextID {
			t.Fatalf("A2A task info = %#v; want task %q and context %q", info, request.TaskID, request.ContextID)
		}
	}
	if eventCount < 3 {
		t.Fatalf("A2A events = %d, want progress and terminal events", eventCount)
	}
}

type cancelContextKey struct{}

type catalogFunc func(agent.Context, byo.ProductID) (byo.Product, error)

func (f catalogFunc) Lookup(ctx agent.Context, productID byo.ProductID) (byo.Product, error) {
	return f(ctx, productID)
}

func newRunner(t *testing.T, service session.Service, extractor Extractor, catalog Catalog, timeout time.Duration) *runner.Runner {
	t.Helper()
	rootAgent, err := New(Config{
		Extractor:   extractor,
		Catalog:     catalog,
		CallTimeout: timeout,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.New(runner.Config{
		AppName:        testAppName,
		Agent:          rootAgent,
		SessionService: service,
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func createSession(t *testing.T, service session.Service, sessionID string) {
	t.Helper()
	if _, err := service.Create(t.Context(), &session.CreateRequest{
		AppName:   testAppName,
		UserID:    testUserID,
		SessionID: sessionID,
	}); err != nil {
		t.Fatal(err)
	}
}

func runTurn(t *testing.T, agentRunner *runner.Runner, sessionID, input string) []*session.Event {
	t.Helper()
	events, err := runTurnWithError(t, agentRunner, sessionID, input)
	if err != nil {
		t.Fatal(err)
	}
	return events
}

func runTurnWithError(t *testing.T, agentRunner *runner.Runner, sessionID, input string) ([]*session.Event, error) {
	t.Helper()
	return runTurnWithContext(t, t.Context(), agentRunner, sessionID, input)
}

func runTurnWithContext(t *testing.T, ctx context.Context, agentRunner *runner.Runner, sessionID, input string) ([]*session.Event, error) {
	t.Helper()
	var events []*session.Event
	var runErr error
	for event, err := range agentRunner.Run(ctx, testUserID, sessionID,
		genai.NewContentFromText(input, genai.RoleUser), agent.RunConfig{}) {
		if err != nil {
			runErr = errors.Join(runErr, err)
		}
		if event != nil {
			events = append(events, event)
		}
	}
	return events, runErr
}

func finalText(events []*session.Event) string {
	for index := len(events) - 1; index >= 0; index-- {
		event := events[index]
		if event.Content != nil && !event.Partial {
			var content []string
			for _, part := range event.Content.Parts {
				if part != nil && part.Text != "" {
					content = append(content, part.Text)
				}
			}
			return strings.Join(content, "")
		}
	}
	return ""
}

func testCatalog() byo.Catalog {
	return byo.Catalog{
		"star-widget": {Name: "Star Widget", UnitPriceCents: 1250},
		"moon-gadget": {Name: "Moon Gadget", UnitPriceCents: 2400},
	}
}

func cloneDraft(draft byo.Draft) byo.Draft {
	clone := byo.Draft{Positions: make([]byo.Position, len(draft.Positions))}
	if draft.BudgetCents != nil {
		budget := *draft.BudgetCents
		clone.BudgetCents = &budget
	}
	for index, position := range draft.Positions {
		clone.Positions[index].ProductID = position.ProductID
		if position.Quantity != nil {
			quantity := *position.Quantity
			clone.Positions[index].Quantity = &quantity
		}
	}
	return clone
}

func assertPosition(t *testing.T, got, want byo.Position) {
	t.Helper()
	if got.ProductID != want.ProductID {
		t.Fatalf("product_id = %q, want %q", got.ProductID, want.ProductID)
	}
	switch {
	case got.Quantity == nil && want.Quantity == nil:
		return
	case got.Quantity == nil || want.Quantity == nil:
		t.Fatalf("quantity = %v, want %v", got.Quantity, want.Quantity)
	case *got.Quantity != *want.Quantity:
		t.Fatalf("quantity = %d, want %d", *got.Quantity, *want.Quantity)
	}
}
