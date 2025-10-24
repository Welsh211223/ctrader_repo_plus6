from fastapi import APIRouter

router = APIRouter()


@router.post("/v1/agent/summary")
def agent_summary(payload: dict):
    text = payload.get("text", "")
    return {"result": f"processed: {text}"}
