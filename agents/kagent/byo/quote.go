package quote

import (
	"errors"
	"fmt"
	"strconv"
)

type ProductID string
type Cents int64
type Quantity int64

type Product struct {
	Name           string
	UnitPriceCents Cents
}

type Catalog map[ProductID]Product

type Position struct {
	ProductID ProductID `json:"product_id"`
	Quantity  *Quantity `json:"quantity,omitempty"`
}

type Draft struct {
	Positions   []Position `json:"positions"`
	BudgetCents *Cents     `json:"budget_cents,omitempty"`
}

type Status string

const (
	StatusIncomplete Status = "incomplete"
	StatusComplete   Status = "complete"
)

type MissingField string

const (
	MissingPositions MissingField = "positions"
	MissingBudget    MissingField = "budget"
	MissingProductID MissingField = "product_id"
	MissingQuantity  MissingField = "quantity"
)

type MissingInput struct {
	PositionIndex int
	Field         MissingField
}

type Line struct {
	ProductID      ProductID
	ProductName    string
	Quantity       Quantity
	UnitPriceCents Cents
	TotalCents     Cents
}

type Result struct {
	Status               Status
	Missing              []MissingInput
	Lines                []Line
	TotalCents           Cents
	BudgetRemainingCents Cents
	WithinBudget         bool
}

var (
	ErrInvalidQuantity  = errors.New("invalid quantity")
	ErrInvalidBudget    = errors.New("invalid budget")
	ErrUnknownProduct   = errors.New("unknown product")
	ErrInvalidCatalog   = errors.New("invalid catalog product")
	ErrDuplicateProduct = errors.New("duplicate product")
	ErrPositionNotFound = errors.New("position not found")
	ErrOverflow         = errors.New("integer overflow")
)

const maxInt64 = int64(1<<63 - 1)

func ParseQuantity(value string) (Quantity, error) {
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		if errors.Is(err, strconv.ErrRange) {
			return 0, fmt.Errorf("%w: quantity %q", ErrOverflow, value)
		}
		return 0, fmt.Errorf("%w: %q must be a whole number", ErrInvalidQuantity, value)
	}
	if parsed <= 0 {
		return 0, fmt.Errorf("%w: quantity must be positive", ErrInvalidQuantity)
	}
	return Quantity(parsed), nil
}

func ChangeQuantity(draft Draft, productID ProductID, quantity Quantity) (Draft, error) {
	if productID == "" {
		return Draft{}, fmt.Errorf("%w: product ID is required", ErrPositionNotFound)
	}
	if quantity <= 0 {
		return Draft{}, fmt.Errorf("%w: quantity must be positive", ErrInvalidQuantity)
	}

	updated := cloneDraft(draft)
	match := -1
	for index, position := range updated.Positions {
		if position.ProductID != productID {
			continue
		}
		if match != -1 {
			return Draft{}, fmt.Errorf("%w: %q", ErrDuplicateProduct, productID)
		}
		match = index
	}
	if match == -1 {
		return Draft{}, fmt.Errorf("%w: %q", ErrPositionNotFound, productID)
	}

	updatedQuantity := quantity
	updated.Positions[match].Quantity = &updatedQuantity
	return updated, nil
}

func Evaluate(draft Draft, catalog Catalog) (Result, error) {
	missing := MissingInputs(draft)
	if len(missing) > 0 {
		return Result{Status: StatusIncomplete, Missing: missing}, nil
	}
	if *draft.BudgetCents < 0 {
		return Result{}, fmt.Errorf("%w: budget cannot be negative", ErrInvalidBudget)
	}

	seen := make(map[ProductID]struct{}, len(draft.Positions))
	lines := make([]Line, 0, len(draft.Positions))
	var total Cents
	for index, position := range draft.Positions {
		if _, exists := seen[position.ProductID]; exists {
			return Result{}, fmt.Errorf("%w: %q", ErrDuplicateProduct, position.ProductID)
		}
		seen[position.ProductID] = struct{}{}

		product, exists := catalog[position.ProductID]
		if !exists {
			return Result{}, fmt.Errorf("%w: %q", ErrUnknownProduct, position.ProductID)
		}
		if product.UnitPriceCents < 0 {
			return Result{}, fmt.Errorf("%w: %q has a negative price", ErrInvalidCatalog, position.ProductID)
		}
		if *position.Quantity <= 0 {
			return Result{}, fmt.Errorf("%w: position %d must have a positive quantity", ErrInvalidQuantity, index)
		}

		if int64(product.UnitPriceCents) > maxInt64/int64(*position.Quantity) {
			return Result{}, fmt.Errorf("%w: line total for %q", ErrOverflow, position.ProductID)
		}
		lineTotal := Cents(int64(product.UnitPriceCents) * int64(*position.Quantity))
		if int64(lineTotal) > maxInt64-int64(total) {
			return Result{}, fmt.Errorf("%w: quote total", ErrOverflow)
		}
		total += lineTotal
		lines = append(lines, Line{
			ProductID:      position.ProductID,
			ProductName:    product.Name,
			Quantity:       *position.Quantity,
			UnitPriceCents: product.UnitPriceCents,
			TotalCents:     lineTotal,
		})
	}

	remaining := Cents(int64(*draft.BudgetCents) - int64(total))
	return Result{
		Status:               StatusComplete,
		Lines:                lines,
		TotalCents:           total,
		BudgetRemainingCents: remaining,
		WithinBudget:         remaining >= 0,
	}, nil
}

func MissingInputs(draft Draft) []MissingInput {
	return missingInputs(draft)
}

func missingInputs(draft Draft) []MissingInput {
	var missing []MissingInput
	if draft.BudgetCents == nil {
		missing = append(missing, MissingInput{PositionIndex: -1, Field: MissingBudget})
	}
	if len(draft.Positions) == 0 {
		missing = append(missing, MissingInput{PositionIndex: -1, Field: MissingPositions})
	}
	for index, position := range draft.Positions {
		if position.ProductID == "" {
			missing = append(missing, MissingInput{PositionIndex: index, Field: MissingProductID})
		}
		if position.Quantity == nil {
			missing = append(missing, MissingInput{PositionIndex: index, Field: MissingQuantity})
		}
	}
	return missing
}

func cloneDraft(draft Draft) Draft {
	clone := Draft{Positions: make([]Position, len(draft.Positions))}
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
