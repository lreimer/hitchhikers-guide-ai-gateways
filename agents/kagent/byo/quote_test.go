package quote

import (
	"errors"
	"testing"
)

func TestEvaluateQuoteAndBudgetOverrun(t *testing.T) {
	draft := completeDraft(8000,
		Position{ProductID: "star-widget", Quantity: quantity(3)},
		Position{ProductID: "moon-gadget", Quantity: quantity(2)},
	)

	result, err := Evaluate(draft, testCatalog())
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != StatusComplete {
		t.Fatalf("status = %q, want %q", result.Status, StatusComplete)
	}
	if result.TotalCents != 8550 {
		t.Errorf("total = %d cents, want 8550", result.TotalCents)
	}
	if result.BudgetRemainingCents != -550 {
		t.Errorf("budget difference = %d cents, want -550", result.BudgetRemainingCents)
	}
	if result.WithinBudget {
		t.Error("over-budget quote must not be marked within budget")
	}
}

func TestChangeQuantityPreservesOtherDraftValues(t *testing.T) {
	draft := completeDraft(8000,
		Position{ProductID: "star-widget", Quantity: quantity(3)},
		Position{ProductID: "moon-gadget", Quantity: quantity(2)},
	)

	updated, err := ChangeQuantity(draft, "moon-gadget", 1)
	if err != nil {
		t.Fatal(err)
	}
	if *updated.BudgetCents != 8000 || updated.Positions[0].ProductID != "star-widget" ||
		*updated.Positions[0].Quantity != 3 {
		t.Fatalf("unrelated draft values changed: %#v", updated)
	}
	if *updated.Positions[1].Quantity != 1 {
		t.Fatalf("updated quantity = %d, want 1", *updated.Positions[1].Quantity)
	}
	if *draft.Positions[1].Quantity != 2 {
		t.Fatal("ChangeQuantity mutated the original draft")
	}

	result, err := Evaluate(updated, testCatalog())
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalCents != 6150 || result.BudgetRemainingCents != 1850 || !result.WithinBudget {
		t.Errorf("updated result = total %d, remaining %d, within budget %t; want 6150, 1850, true",
			result.TotalCents, result.BudgetRemainingCents, result.WithinBudget)
	}
}

func TestEvaluateReportsMissingInputsAsIncomplete(t *testing.T) {
	tests := []struct {
		name  string
		draft Draft
		want  []MissingInput
	}{
		{
			name: "missing quantity and budget",
			draft: Draft{Positions: []Position{
				{ProductID: "star-widget"},
			}},
			want: []MissingInput{
				{PositionIndex: -1, Field: MissingBudget},
				{PositionIndex: 0, Field: MissingQuantity},
			},
		},
		{
			name: "missing product identifier",
			draft: Draft{
				Positions:   []Position{{Quantity: quantity(1)}},
				BudgetCents: cents(8000),
			},
			want: []MissingInput{{PositionIndex: 0, Field: MissingProductID}},
		},
		{
			name:  "missing positions",
			draft: Draft{BudgetCents: cents(8000)},
			want:  []MissingInput{{PositionIndex: -1, Field: MissingPositions}},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result, err := Evaluate(test.draft, testCatalog())
			if err != nil {
				t.Fatal(err)
			}
			if result.Status != StatusIncomplete {
				t.Fatalf("status = %q, want %q", result.Status, StatusIncomplete)
			}
			if len(result.Missing) != len(test.want) {
				t.Fatalf("missing fields = %#v, want %#v", result.Missing, test.want)
			}
			for index := range test.want {
				if result.Missing[index] != test.want[index] {
					t.Errorf("missing[%d] = %#v, want %#v", index, result.Missing[index], test.want[index])
				}
			}
			if result.TotalCents != 0 || len(result.Lines) != 0 {
				t.Errorf("incomplete result must not contain calculated totals or lines: %#v", result)
			}
		})
	}
}

func TestEvaluateRejectsUnknownProductAndInvalidQuantities(t *testing.T) {
	tests := []struct {
		name    string
		draft   Draft
		catalog Catalog
		wantErr error
	}{
		{
			name:    "unknown product",
			draft:   completeDraft(8000, Position{ProductID: "unknown", Quantity: quantity(1)}),
			catalog: testCatalog(),
			wantErr: ErrUnknownProduct,
		},
		{
			name:    "negative quantity",
			draft:   completeDraft(8000, Position{ProductID: "star-widget", Quantity: quantity(-1)}),
			catalog: testCatalog(),
			wantErr: ErrInvalidQuantity,
		},
		{
			name: "duplicate product",
			draft: completeDraft(8000,
				Position{ProductID: "star-widget", Quantity: quantity(1)},
				Position{ProductID: "star-widget", Quantity: quantity(2)},
			),
			catalog: testCatalog(),
			wantErr: ErrDuplicateProduct,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Evaluate(test.draft, test.catalog)
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestParseQuantityRejectsNonIntegerAndOverflow(t *testing.T) {
	if _, err := ParseQuantity("1.5"); !errors.Is(err, ErrInvalidQuantity) {
		t.Errorf("ParseQuantity(1.5) error = %v, want ErrInvalidQuantity", err)
	}
	if _, err := ParseQuantity("-1"); !errors.Is(err, ErrInvalidQuantity) {
		t.Errorf("ParseQuantity(-1) error = %v, want ErrInvalidQuantity", err)
	}
	if _, err := ParseQuantity("9223372036854775808"); !errors.Is(err, ErrOverflow) {
		t.Errorf("ParseQuantity(overflow) error = %v, want ErrOverflow", err)
	}
}

func TestEvaluateDetectsMultiplicationAndAdditionOverflow(t *testing.T) {
	max := Cents(maxInt64)
	catalog := Catalog{
		"expensive": {Name: "Expensive", UnitPriceCents: max},
	}
	tests := []struct {
		name    string
		draft   Draft
		catalog Catalog
	}{
		{
			name:    "multiplication",
			draft:   completeDraft(Cents(maxInt64), Position{ProductID: "expensive", Quantity: quantity(2)}),
			catalog: catalog,
		},
		{
			name: "addition",
			draft: completeDraft(Cents(maxInt64),
				Position{ProductID: "expensive", Quantity: quantity(1)},
				Position{ProductID: "expensive-2", Quantity: quantity(1)},
			),
			catalog: Catalog{
				"expensive":   {Name: "Expensive", UnitPriceCents: max},
				"expensive-2": {Name: "Also Expensive", UnitPriceCents: 1},
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := Evaluate(test.draft, test.catalog)
			if !errors.Is(err, ErrOverflow) {
				t.Fatalf("error = %v, want ErrOverflow", err)
			}
		})
	}
}

func TestChangeQuantityRejectsMissingPosition(t *testing.T) {
	_, err := ChangeQuantity(completeDraft(8000,
		Position{ProductID: "star-widget", Quantity: quantity(3)},
	), "moon-gadget", 1)
	if !errors.Is(err, ErrPositionNotFound) {
		t.Fatalf("error = %v, want ErrPositionNotFound", err)
	}
}

func testCatalog() Catalog {
	return Catalog{
		"star-widget": {Name: "Star Widget", UnitPriceCents: 1250},
		"moon-gadget": {Name: "Moon Gadget", UnitPriceCents: 2400},
	}
}

func completeDraft(budget Cents, positions ...Position) Draft {
	return Draft{Positions: positions, BudgetCents: cents(budget)}
}

func cents(value Cents) *Cents {
	return &value
}

func quantity(value Quantity) *Quantity {
	return &value
}
