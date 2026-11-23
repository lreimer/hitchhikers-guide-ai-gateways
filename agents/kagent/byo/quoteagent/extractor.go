package quoteagent

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/model"
	"google.golang.org/genai"
)

type ModelExtractor struct {
	model model.LLM
}

func NewModelExtractor(model model.LLM) (*ModelExtractor, error) {
	if model == nil {
		return nil, errors.New("quote extraction model is required")
	}
	return &ModelExtractor{model: model}, nil
}

func (e *ModelExtractor) Extract(ctx context.Context, input string, draft byo.Draft) (Patch, error) {
	if err := ctx.Err(); err != nil {
		return Patch{}, err
	}
	encodedDraft, err := json.Marshal(draft)
	if err != nil {
		return Patch{}, fmt.Errorf("encode current quote draft: %w", err)
	}
	prompt := fmt.Sprintf(`Extract only quote changes from the user's latest message.

Return exactly one JSON object with this shape:
{"positions":[{"product_id":"star-widget","quantity":3}],"budget_cents":8000,"question":""}

Rules:
- Use exact catalog IDs: "star-widget" and "moon-gadget". Do not invent a product ID or price.
- Quantities must be positive whole numbers. A quantity update to an existing product changes only that product.
- Budget is an integer number of USD cents. Omit it when unchanged.
- Omit unchanged positions. Use "position_index" only to fill or clarify an existing incomplete position.
- If any requested detail is missing or ambiguous, do not guess it. Set "question" to a concise ordinary follow-up question; this is dialogue, not an approval request.
- Never calculate prices, totals, or budget status.
- Do not use Markdown fences or any text outside the JSON object.

Current draft: %s
Latest user message: %q`, encodedDraft, input)
	request := &model.LLMRequest{
		Model: e.model.Name(),
		Contents: []*genai.Content{
			genai.NewContentFromText(prompt, genai.RoleUser),
		},
	}

	var output strings.Builder
	for response, err := range e.model.GenerateContent(ctx, request, false) {
		if err != nil {
			return Patch{}, err
		}
		if response == nil || response.Content == nil {
			continue
		}
		for _, part := range response.Content.Parts {
			if part != nil {
				output.WriteString(part.Text)
			}
		}
	}
	if err := ctx.Err(); err != nil {
		return Patch{}, err
	}
	raw := strings.TrimSpace(output.String())
	if raw == "" {
		return Patch{}, errors.New("quote extraction returned no content")
	}

	var patch Patch
	decoder := json.NewDecoder(bytes.NewBufferString(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&patch); err != nil {
		return Patch{}, fmt.Errorf("decode quote extraction: %w", err)
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		if err == nil {
			return Patch{}, errors.New("quote extraction returned multiple JSON values")
		}
		return Patch{}, fmt.Errorf("decode trailing quote extraction content: %w", err)
	}
	return patch, nil
}
