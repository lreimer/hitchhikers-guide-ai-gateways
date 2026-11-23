package quoteagent

import (
	"context"
	"encoding/json"
	"testing"

	configv1 "github.com/kagent-dev/kagent/go/api/gen/kagent/config/v1"
	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
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
