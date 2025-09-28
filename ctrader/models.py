from __future__ import annotations

from typing import Dict, List, Literal, Optional

from pydantic import BaseModel, Field, field_validator


class Holding(BaseModel):
    symbol: str = Field(..., description="Asset symbol, e.g., BTC")
    amount: float = Field(..., ge=0.0)

    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()


class Quote(BaseModel):
    symbol: str
    price: float = Field(..., gt=0.0)

    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()


class Allocation(BaseModel):
    weights: Dict[str, float] = Field(default_factory=dict)

    @field_validator("weights")
    @classmethod
    def validate_weights(cls, w: Dict[str, float]) -> Dict[str, float]:
        total = sum(w.values())
        if not w:
            raise ValueError("Allocation weights cannot be empty.")
        if not (0.999 <= total <= 1.001):
            raise ValueError(f"Weights must sum to 1.0 Â±0.001, got {total:.6f}")
        if any(x < 0 for x in w.values()):
            raise ValueError("Weights must be non-negative.")
        if abs(total - 1.0) > 1e-9:
            w = {k: v / total for k, v in w.items()}
        return {k.upper(): v for k, v in w.items()}


Side = Literal["buy", "sell"]


class Order(BaseModel):
    side: Side
    symbol: str
    amount: float = Field(..., gt=0.0)
    est_value: float = Field(..., gt=0.0)
    est_fee: float = Field(default=0.0, ge=0.0)

    @field_validator("symbol")
    @classmethod
    def upper(cls, v: str) -> str:
        return v.upper()


class TradePlan(BaseModel):
    orders: List[Order] = Field(default_factory=list)
    portfolio_value: float = 0.0
    note: Optional[str] = None

    def summary(self) -> Dict[str, float]:
        buys = sum(o.est_value for o in self.orders if o.side == "buy")
        sells = sum(o.est_value for o in self.orders if o.side == "sell")
        fees = sum(o.est_fee for o in self.orders)
        return {"buys": buys, "sells": sells, "fees": fees}
