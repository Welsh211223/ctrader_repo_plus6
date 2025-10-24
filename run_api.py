from importlib import import_module

from fastapi import FastAPI

app = FastAPI()


@app.get("/_up")
def _up():
    return {"ok": True}


@app.get("/__routes")
def __routes():
    return [
        getattr(r, "path", None) for r in app.router.routes if getattr(r, "path", None)
    ]


try:
    mod = import_module(".api.server")
    router = getattr(mod, "router", None)
    if router is not None:
        app.include_router(router)
except Exception:
    # Keep app running even if import fails
    pass
