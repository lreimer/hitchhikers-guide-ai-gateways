package quoteagent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"sync"

	"github.com/kagent-dev/kagent/go/adk/pkg/mcp"
	configv1 "github.com/kagent-dev/kagent/go/api/gen/kagent/config/v1"
	byo "github.com/lreimer/hitchhikers-guide-ai-gateways/agents/kagent/byo"
	"google.golang.org/adk/v2/agent"
	"google.golang.org/adk/v2/tool"
)

const catalogToolName = "catalog_lookup_product"

type mcpCatalog struct {
	toolset tool.Toolset

	mu         sync.Mutex
	lookupTool mcpLookupTool
	discovery  *toolDiscovery
}

type toolDiscovery struct {
	done chan struct{}
	tool mcpLookupTool
	err  error
}

type mcpLookupTool interface {
	Run(agent.Context, any) (map[string]any, error)
}

func NewMCPCatalog(ctx context.Context, config *configv1.ADKAgentConfig) (Catalog, error) {
	if config == nil {
		return nil, errors.New("agent bootstrap configuration is required")
	}
	var bindings []*configv1.ADKHTTPMCPServerConfig
	for _, binding := range config.GetHttpTools() {
		if binding == nil {
			continue
		}
		for _, name := range binding.GetTools() {
			if name == catalogToolName {
				bindings = append(bindings, binding)
				break
			}
		}
	}
	if len(bindings) != 1 {
		return nil, fmt.Errorf("expected exactly one protected MCP binding for %q, found %d",
			catalogToolName, len(bindings))
	}
	binding := bindings[0]
	if binding.GetRequireApproval() {
		return nil, fmt.Errorf("MCP tool %q must use normal tool execution, not approval", catalogToolName)
	}
	if len(binding.GetTools()) != 1 || binding.GetTools()[0] != catalogToolName {
		return nil, fmt.Errorf("MCP binding for %q must not expose additional tools", catalogToolName)
	}

	toolsets := mcp.CreateToolsets(ctx, []*configv1.ADKHTTPMCPServerConfig{binding}, nil, nil, false, nil)
	if len(toolsets) != 1 {
		return nil, fmt.Errorf("create protected catalog MCP toolset: expected one toolset, found %d", len(toolsets))
	}
	return &mcpCatalog{toolset: toolsets[0]}, nil
}

func (c *mcpCatalog) Lookup(ctx agent.Context, productID byo.ProductID) (byo.Product, error) {
	if err := ctx.Err(); err != nil {
		return byo.Product{}, err
	}
	lookup, err := c.tool(ctx)
	if err != nil {
		return byo.Product{}, err
	}
	if err := ctx.Err(); err != nil {
		return byo.Product{}, err
	}
	result, err := lookup.Run(ctx, map[string]any{"product_id": string(productID)})
	if err != nil {
		return byo.Product{}, err
	}

	output, ok := result["output"].(map[string]any)
	if !ok {
		return byo.Product{}, fmt.Errorf("catalog tool returned unexpected output type %T", result["output"])
	}
	return parseProduct(output, productID)
}

func (c *mcpCatalog) tool(ctx agent.ReadonlyContext) (mcpLookupTool, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.mu.Lock()
	if c.lookupTool != nil {
		lookupTool := c.lookupTool
		c.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return lookupTool, nil
	}
	if discovery := c.discovery; discovery != nil {
		c.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-discovery.done:
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		return discovery.tool, discovery.err
	}

	discovery := &toolDiscovery{done: make(chan struct{})}
	c.discovery = discovery
	c.mu.Unlock()

	lookupTool, err := c.discover(ctx)

	c.mu.Lock()
	if err == nil {
		c.lookupTool = lookupTool
	}
	discovery.tool = lookupTool
	discovery.err = err
	c.discovery = nil
	close(discovery.done)
	c.mu.Unlock()

	if err != nil {
		return nil, err
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return lookupTool, nil
}

func (c *mcpCatalog) discover(ctx agent.ReadonlyContext) (mcpLookupTool, error) {
	tools, err := c.toolset.Tools(ctx)
	if err != nil {
		return nil, fmt.Errorf("discover protected catalog tool: %w", err)
	}
	var lookupTool mcpLookupTool
	for _, candidate := range tools {
		if candidate.Name() != catalogToolName {
			continue
		}
		lookup, ok := candidate.(mcpLookupTool)
		if !ok {
			return nil, fmt.Errorf("catalog tool %q cannot execute MCP calls", catalogToolName)
		}
		if lookupTool != nil {
			return nil, fmt.Errorf("catalog tool %q is ambiguous", catalogToolName)
		}
		lookupTool = lookup
	}
	if lookupTool == nil {
		return nil, fmt.Errorf("protected MCP tool %q was not discovered", catalogToolName)
	}
	return lookupTool, nil
}

func parseProduct(values map[string]any, requestedID byo.ProductID) (byo.Product, error) {
	productID, ok := values["product_id"].(string)
	if !ok || productID != string(requestedID) {
		return byo.Product{}, fmt.Errorf("catalog returned product ID %v for request %q", values["product_id"], requestedID)
	}
	name, ok := values["name"].(string)
	if !ok || name == "" {
		return byo.Product{}, errors.New("catalog returned an empty or invalid product name")
	}
	price, ok := values["price"]
	if !ok {
		return byo.Product{}, errors.New("catalog returned no product price")
	}
	cents, err := priceToCents(price)
	if err != nil {
		return byo.Product{}, fmt.Errorf("catalog returned invalid price: %w", err)
	}
	return byo.Product{Name: name, UnitPriceCents: cents}, nil
}

func priceToCents(value any) (byo.Cents, error) {
	var decimal string
	switch price := value.(type) {
	case string:
		decimal = price
	case json.Number:
		decimal = string(price)
	case float64:
		decimal = strconv.FormatFloat(price, 'f', -1, 64)
	case float32:
		decimal = strconv.FormatFloat(float64(price), 'f', -1, 32)
	case int:
		decimal = strconv.Itoa(price)
	case int64:
		decimal = strconv.FormatInt(price, 10)
	default:
		return 0, fmt.Errorf("unsupported price type %T", value)
	}
	rational, ok := new(big.Rat).SetString(decimal)
	if !ok || rational.Sign() < 0 {
		return 0, fmt.Errorf("price %q is not a non-negative decimal", decimal)
	}
	rational.Mul(rational, big.NewRat(100, 1))
	if !rational.IsInt() || !rational.Num().IsInt64() {
		return 0, fmt.Errorf("price %q does not fit an integer number of cents", decimal)
	}
	return byo.Cents(rational.Num().Int64()), nil
}
