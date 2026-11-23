package quoteagent

import (
	"context"
	"errors"
	"iter"
	"strings"
	"testing"

	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/model"
	"google.golang.org/genai"
)

type modelFake struct {
	response string
	err      error
	calls    int
	request  *model.LLMRequest
}

func (m *modelFake) Name() string { return "model-double" }

func (m *modelFake) GenerateContent(_ context.Context, request *model.LLMRequest, _ bool) iter.Seq2[*model.LLMResponse, error] {
	return func(yield func(*model.LLMResponse, error) bool) {
		m.calls++
		m.request = request
		if m.err != nil {
			yield(nil, m.err)
			return
		}
		yield(&model.LLMResponse{
			Content: genai.NewContentFromText(m.response, genai.RoleModel),
		}, nil)
	}
}

func TestModelExtractorUsesPlainJSONAndParsesTypedPatch(t *testing.T) {
	modelDouble := &modelFake{
		response: `{"positions":[{"product_id":"moon-gadget","quantity":1}],"question":""}`,
	}
	extractor, err := NewModelExtractor(modelDouble)
	if err != nil {
		t.Fatal(err)
	}
	quantity := byo.Quantity(2)
	patch, err := extractor.Extract(t.Context(), "change Moon Gadget", byo.Draft{
		Positions: []byo.Position{{ProductID: "moon-gadget", Quantity: &quantity}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if modelDouble.calls != 1 || modelDouble.request.Config != nil || len(modelDouble.request.Tools) != 0 {
		t.Fatalf("model calls = %d, request config = %#v, tools = %#v; want one plain model call",
			modelDouble.calls, modelDouble.request.Config, modelDouble.request.Tools)
	}
	if !strings.Contains(modelDouble.request.Contents[0].Parts[0].Text, `"quantity":2`) {
		t.Fatalf("model prompt omitted the existing draft: %q", modelDouble.request.Contents[0].Parts[0].Text)
	}
	if len(patch.Positions) != 1 || patch.Positions[0].ProductID != "moon-gadget" ||
		patch.Positions[0].Quantity == nil || *patch.Positions[0].Quantity != 1 {
		t.Fatalf("parsed patch = %#v; want one typed Moon Gadget quantity update", patch)
	}
}

func TestModelExtractorRejectsMalformedOutputAndFractionalQuantity(t *testing.T) {
	for _, response := range []string{
		"```json\n{\"positions\":[]}\n```",
		`{"positions":[{"product_id":"star-widget","quantity":1.5}]}`,
		`{"positions":[]} {"positions":[]}`,
	} {
		t.Run(response, func(t *testing.T) {
			extractor, err := NewModelExtractor(&modelFake{response: response})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := extractor.Extract(t.Context(), "quote", byo.Draft{}); err == nil {
				t.Fatal("Extract() succeeded for invalid model output")
			}
		})
	}
}

func TestModelExtractorPropagatesRateLimitAndSkipsCallsWhenCanceled(t *testing.T) {
	rateLimit := errors.New("HTTP 429: rate limit")
	modelDouble := &modelFake{err: rateLimit}
	extractor, err := NewModelExtractor(modelDouble)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := extractor.Extract(t.Context(), "quote", byo.Draft{}); !errors.Is(err, rateLimit) {
		t.Fatalf("Extract() error = %v; want the provider's 429 error", err)
	}
	if modelDouble.calls != 1 {
		t.Fatalf("model calls = %d, want one attempt without retry", modelDouble.calls)
	}

	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := extractor.Extract(ctx, "quote", byo.Draft{}); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled Extract() error = %v; want context.Canceled", err)
	}
	if modelDouble.calls != 1 {
		t.Fatalf("model calls after cancellation = %d, want no further call", modelDouble.calls)
	}
}
