package quoteagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"iter"
	"strings"
	"time"

	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/session"
	"google.golang.org/genai"
)

const (
	AgentName             = "product_quote_planner"
	draftStateKey         = "product_quote_draft"
	clarificationStateKey = "product_quote_clarification"
	defaultCallTimeout    = 30 * time.Second
	maxCatalogLookups     = 8
)

type Patch struct {
	Positions   []PositionPatch `json:"positions,omitempty"`
	BudgetCents *byo.Cents      `json:"budget_cents,omitempty"`
	Question    string          `json:"question,omitempty"`
}

type PositionPatch struct {
	Index     *int          `json:"position_index,omitempty"`
	ProductID byo.ProductID `json:"product_id,omitempty"`
	Quantity  *byo.Quantity `json:"quantity,omitempty"`
}

type ClarificationContext struct {
	UserRequest string `json:"user_request,omitempty"`
	Question    string `json:"question,omitempty"`
	LatestReply string `json:"latest_reply,omitempty"`
}

type Extractor interface {
	Extract(context.Context, string, byo.Draft, ClarificationContext) (Patch, error)
}

type Catalog interface {
	Lookup(agent.Context, byo.ProductID) (byo.Product, error)
}

type Config struct {
	Extractor         Extractor
	Catalog           Catalog
	CallTimeout       time.Duration
	MaxCatalogLookups int
}

type quoteAgent struct {
	extractor Extractor
	catalog   Catalog
	timeout   time.Duration
	maxLookup int
}

func New(cfg Config) (agent.Agent, error) {
	if cfg.Extractor == nil {
		return nil, errors.New("quote extractor is required")
	}
	if cfg.Catalog == nil {
		return nil, errors.New("product catalog is required")
	}
	if cfg.CallTimeout <= 0 {
		cfg.CallTimeout = defaultCallTimeout
	}
	if cfg.MaxCatalogLookups <= 0 {
		cfg.MaxCatalogLookups = maxCatalogLookups
	}

	implementation := &quoteAgent{
		extractor: cfg.Extractor,
		catalog:   cfg.Catalog,
		timeout:   cfg.CallTimeout,
		maxLookup: cfg.MaxCatalogLookups,
	}
	return agent.New(agent.Config{
		Name:        AgentName,
		Description: "Builds a product quote with catalog-backed prices and deterministic budget calculations.",
		Run:         implementation.run,
	})
}

func (a *quoteAgent) run(invocation agent.InvocationContext) iter.Seq2[*session.Event, error] {
	return func(yield func(*session.Event, error) bool) {
		actions := &session.EventActions{
			StateDelta:    make(map[string]any),
			ArtifactDelta: make(map[string]int64),
		}
		runContext := agent.NewCallbackContext(invocation, actions)
		if err := runContext.Err(); err != nil {
			yield(nil, err)
			return
		}

		input := textFromContent(runContext.UserContent())
		if input == "" {
			yield(nil, errors.New("quote request must contain text"))
			return
		}
		if !yield(progressEvent(invocation, "Reading quote details."), nil) {
			return
		}

		draft, err := loadDraft(runContext)
		if err != nil {
			yield(nil, fmt.Errorf("load quote session state: %w", err))
			return
		}
		clarification, err := loadClarification(runContext)
		if err != nil {
			yield(nil, fmt.Errorf("load quote clarification state: %w", err))
			return
		}

		modelContext, cancelModel := context.WithTimeout(invocation, a.timeout)
		patch, err := a.extractor.Extract(modelContext, input, draft, clarification)
		modelErr := modelContext.Err()
		cancelModel()
		if err != nil {
			yield(nil, fmt.Errorf("extract quote details: %w", err))
			return
		}
		if modelErr != nil {
			yield(nil, fmt.Errorf("extract quote details: %w", modelErr))
			return
		}
		if err := runContext.Err(); err != nil {
			yield(nil, err)
			return
		}

		updated, err := applyPatch(draft, patch)
		if err != nil {
			yield(nil, err)
			return
		}
		if strings.TrimSpace(patch.Question) != "" {
			if err := persistDraft(runContext, updated); err != nil {
				yield(nil, fmt.Errorf("save quote session state: %w", err))
				return
			}
			question := strings.TrimSpace(patch.Question)
			if err := persistClarification(runContext, nextClarification(clarification, input, question)); err != nil {
				yield(nil, fmt.Errorf("save quote clarification state: %w", err))
				return
			}
			yield(finalEvent(invocation, actions, question), nil)
			return
		}

		if missing := byo.MissingInputs(updated); len(missing) > 0 {
			if err := persistDraft(runContext, updated); err != nil {
				yield(nil, fmt.Errorf("save quote session state: %w", err))
				return
			}
			question := missingQuestion(updated, missing)
			if err := persistClarification(runContext, nextClarification(clarification, input, question)); err != nil {
				yield(nil, fmt.Errorf("save quote clarification state: %w", err))
				return
			}
			yield(finalEvent(invocation, actions, question), nil)
			return
		}

		if err := validateCatalogRequests(updated, a.maxLookup); err != nil {
			yield(nil, err)
			return
		}
		if !yield(progressEvent(invocation, "Checking the product catalog."), nil) {
			return
		}

		catalog := make(byo.Catalog, len(updated.Positions))
		for _, position := range updated.Positions {
			if err := runContext.Err(); err != nil {
				yield(nil, err)
				return
			}
			if _, found := catalog[position.ProductID]; found {
				continue
			}

			toolTimeoutContext, cancelTool := context.WithTimeout(invocation, a.timeout)
			toolInvocation := invocation.WithContext(toolTimeoutContext)
			toolContext := agent.NewToolContext(toolInvocation, "", nil, nil)
			product, lookupErr := a.catalog.Lookup(toolContext, position.ProductID)
			toolErr := toolTimeoutContext.Err()
			cancelTool()
			if lookupErr != nil {
				yield(nil, fmt.Errorf("look up product %q: %w", position.ProductID, lookupErr))
				return
			}
			if toolErr != nil {
				yield(nil, fmt.Errorf("look up product %q: %w", position.ProductID, toolErr))
				return
			}
			if err := runContext.Err(); err != nil {
				yield(nil, err)
				return
			}
			catalog[position.ProductID] = product
		}

		result, err := byo.Evaluate(updated, catalog)
		if err != nil {
			yield(nil, fmt.Errorf("calculate quote: %w", err))
			return
		}
		if err := persistDraft(runContext, updated); err != nil {
			yield(nil, fmt.Errorf("save quote session state: %w", err))
			return
		}
		if err := persistClarification(runContext, ClarificationContext{}); err != nil {
			yield(nil, fmt.Errorf("clear quote clarification state: %w", err))
			return
		}
		if err := runContext.Err(); err != nil {
			yield(nil, err)
			return
		}
		yield(finalEvent(invocation, actions, formatResult(result)), nil)
	}
}

func loadDraft(ctx agent.Context) (byo.Draft, error) {
	value, err := ctx.State().Get(draftStateKey)
	if errors.Is(err, session.ErrStateKeyNotExist) {
		return byo.Draft{}, nil
	}
	if err != nil {
		return byo.Draft{}, err
	}
	encoded, ok := value.(string)
	if !ok {
		return byo.Draft{}, fmt.Errorf("stored quote draft has unexpected type %T", value)
	}

	var draft byo.Draft
	if err := json.Unmarshal([]byte(encoded), &draft); err != nil {
		return byo.Draft{}, fmt.Errorf("decode stored quote draft: %w", err)
	}
	return draft, nil
}

func persistDraft(ctx agent.Context, draft byo.Draft) error {
	encoded, err := json.Marshal(draft)
	if err != nil {
		return fmt.Errorf("encode quote draft: %w", err)
	}
	return ctx.State().Set(draftStateKey, string(encoded))
}

func loadClarification(ctx agent.Context) (ClarificationContext, error) {
	value, err := ctx.State().Get(clarificationStateKey)
	if errors.Is(err, session.ErrStateKeyNotExist) {
		return ClarificationContext{}, nil
	}
	if err != nil {
		return ClarificationContext{}, err
	}
	encoded, ok := value.(string)
	if !ok {
		return ClarificationContext{}, fmt.Errorf("stored quote clarification has unexpected type %T", value)
	}

	var clarification ClarificationContext
	if err := json.Unmarshal([]byte(encoded), &clarification); err != nil {
		return ClarificationContext{}, fmt.Errorf("decode stored quote clarification: %w", err)
	}
	return clarification, nil
}

func persistClarification(ctx agent.Context, clarification ClarificationContext) error {
	encoded, err := json.Marshal(clarification)
	if err != nil {
		return fmt.Errorf("encode quote clarification: %w", err)
	}
	return ctx.State().Set(clarificationStateKey, string(encoded))
}

func nextClarification(previous ClarificationContext, input, question string) ClarificationContext {
	if previous.UserRequest == "" {
		previous.UserRequest = input
	} else {
		previous.LatestReply = input
	}
	previous.Question = question
	return previous
}

func applyPatch(draft byo.Draft, patch Patch) (byo.Draft, error) {
	if patch.BudgetCents != nil {
		if *patch.BudgetCents < 0 {
			return byo.Draft{}, fmt.Errorf("%w: budget cannot be negative", byo.ErrInvalidBudget)
		}
		budget := *patch.BudgetCents
		draft.BudgetCents = &budget
	}

	mergeTargets := make(map[int]int)
	for _, update := range patch.Positions {
		if update.Quantity != nil && *update.Quantity <= 0 {
			return byo.Draft{}, fmt.Errorf("%w: quantity must be positive", byo.ErrInvalidQuantity)
		}
		index, err := positionIndex(draft, update)
		if err != nil {
			return byo.Draft{}, err
		}
		if index == len(draft.Positions) {
			draft.Positions = append(draft.Positions, byo.Position{})
		}
		position := &draft.Positions[index]
		if update.ProductID != "" && position.ProductID == "" {
			if existingIndex := productPositionIndex(draft, update.ProductID, index); existingIndex >= 0 {
				for sourceIndex, targetIndex := range mergeTargets {
					if sourceIndex != index && targetIndex == existingIndex {
						return byo.Draft{}, fmt.Errorf("multiple incomplete positions cannot resolve to product %q in one turn",
							update.ProductID)
					}
				}
				mergeTargets[index] = existingIndex
			}
		}
		if update.ProductID != "" {
			position.ProductID = update.ProductID
		}
		if update.Quantity != nil {
			quantity := *update.Quantity
			position.Quantity = &quantity
		}
	}
	if len(mergeTargets) > 0 {
		removed := make(map[int]struct{}, len(mergeTargets))
		for sourceIndex, targetIndex := range mergeTargets {
			source := draft.Positions[sourceIndex]
			if source.Quantity != nil {
				quantity := *source.Quantity
				draft.Positions[targetIndex].Quantity = &quantity
			}
			removed[sourceIndex] = struct{}{}
		}
		positions := make([]byo.Position, 0, len(draft.Positions)-len(removed))
		for index, position := range draft.Positions {
			if _, shouldRemove := removed[index]; !shouldRemove {
				positions = append(positions, position)
			}
		}
		draft.Positions = positions
	}
	return draft, nil
}

func positionIndex(draft byo.Draft, update PositionPatch) (int, error) {
	if update.ProductID == "" && update.Quantity == nil {
		return 0, errors.New("quote position update must include a product ID or quantity")
	}
	if update.Index != nil {
		index := *update.Index
		if index < 0 || index > len(draft.Positions) {
			return 0, fmt.Errorf("position index %d is out of range", index)
		}
		if index == len(draft.Positions) && update.ProductID == "" && update.Quantity == nil {
			return 0, errors.New("a new quote position requires a product ID or quantity")
		}
		if index < len(draft.Positions) && update.ProductID != "" &&
			draft.Positions[index].ProductID != "" &&
			draft.Positions[index].ProductID != update.ProductID {
			return 0, fmt.Errorf("position %d cannot change product from %q to %q",
				index, draft.Positions[index].ProductID, update.ProductID)
		}
		return index, nil
	}

	if update.ProductID == "" {
		return len(draft.Positions), nil
	}
	for index, position := range draft.Positions {
		if position.ProductID == update.ProductID {
			return index, nil
		}
	}
	return len(draft.Positions), nil
}

func productPositionIndex(draft byo.Draft, productID byo.ProductID, exclude int) int {
	for index, position := range draft.Positions {
		if index != exclude && position.ProductID == productID {
			return index
		}
	}
	return -1
}

func validateCatalogRequests(draft byo.Draft, maxLookups int) error {
	products := make(map[byo.ProductID]struct{}, len(draft.Positions))
	for _, position := range draft.Positions {
		if _, exists := products[position.ProductID]; exists {
			return fmt.Errorf("%w: %q", byo.ErrDuplicateProduct, position.ProductID)
		}
		products[position.ProductID] = struct{}{}
	}
	if len(products) > maxLookups {
		return fmt.Errorf("quote contains %d products; at most %d catalog lookups are allowed per turn",
			len(products), maxLookups)
	}
	return nil
}

func missingQuestion(draft byo.Draft, missing []byo.MissingInput) string {
	questions := make([]string, 0, len(missing))
	for _, item := range missing {
		switch item.Field {
		case byo.MissingPositions:
			questions = append(questions, "Which products and quantities would you like to quote?")
		case byo.MissingBudget:
			questions = append(questions, "What is your budget in USD?")
		case byo.MissingProductID:
			questions = append(questions, fmt.Sprintf("Which product do you mean for position %d?", item.PositionIndex+1))
		case byo.MissingQuantity:
			product := string(draft.Positions[item.PositionIndex].ProductID)
			if product == "" {
				questions = append(questions, fmt.Sprintf("What quantity should I use for position %d?", item.PositionIndex+1))
			} else {
				questions = append(questions, fmt.Sprintf("How many %s would you like?", product))
			}
		}
	}
	return strings.Join(questions, " ")
}

func formatResult(result byo.Result) string {
	var response strings.Builder
	for _, line := range result.Lines {
		fmt.Fprintf(&response, "%d × %s at %s each: %s\n",
			line.Quantity, line.ProductName, formatUSD(line.UnitPriceCents), formatUSD(line.TotalCents))
	}
	fmt.Fprintf(&response, "Total: %s. ", formatUSD(result.TotalCents))
	if result.WithinBudget {
		fmt.Fprintf(&response, "Within budget; %s remains.", formatUSD(result.BudgetRemainingCents))
	} else {
		fmt.Fprintf(&response, "Over budget by %s.", formatUSD(-result.BudgetRemainingCents))
	}
	return response.String()
}

func formatUSD(value byo.Cents) string {
	cents := int64(value)
	sign := ""
	magnitude := uint64(cents)
	if cents < 0 {
		sign = "-"
		magnitude = uint64(-(cents + 1)) + 1
	}
	return fmt.Sprintf("%s$%d.%02d", sign, magnitude/100, magnitude%100)
}

func textFromContent(content *genai.Content) string {
	if content == nil {
		return ""
	}
	var parts []string
	for _, part := range content.Parts {
		if part != nil && strings.TrimSpace(part.Text) != "" {
			parts = append(parts, part.Text)
		}
	}
	return strings.TrimSpace(strings.Join(parts, "\n"))
}

func progressEvent(ctx agent.InvocationContext, text string) *session.Event {
	event := session.NewEvent(ctx, ctx.InvocationID())
	event.Content = genai.NewContentFromText(text, genai.RoleModel)
	event.Partial = true
	return event
}

func finalEvent(ctx agent.InvocationContext, actions *session.EventActions, text string) *session.Event {
	event := session.NewEvent(ctx, ctx.InvocationID())
	event.Content = genai.NewContentFromText(text, genai.RoleModel)
	event.Actions = *actions
	return event
}
