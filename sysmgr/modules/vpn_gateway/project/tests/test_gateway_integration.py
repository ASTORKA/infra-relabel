import base64

import pytest
from httpx import AsyncClient, ASGITransport

from app.main import create_app
from app.config import load_config


@pytest.mark.asyncio
async def test_landing_redirects_to_mirror_target():
    app = create_app("config/gateway.yml")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False) as client:
        resp = await client.get("/")
    assert resp.status_code == 302
    assert resp.headers["location"] == "/buy/wl-lte"


@pytest.mark.asyncio
async def test_business_landing_redirects_to_business_target():
    app = create_app("config/gateway.yml")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False) as client:
        resp = await client.get("/landing/business")
    assert resp.status_code == 302
    assert resp.headers["location"] == "/buy/business"


@pytest.mark.asyncio
async def test_start_preserves_utm_query():
    app = create_app("config/gateway.yml")
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False) as client:
        resp = await client.get("/start?target=wl-lte&utm_source=ad&utm_campaign=spring")
    assert resp.status_code == 302
    assert resp.headers["location"] == "/buy/wl-lte?utm_source=ad&utm_campaign=spring"


@pytest.mark.asyncio
async def test_buy_path_uses_runtime_selector(monkeypatch):
    app = create_app("config/gateway.yml")

    async def fake_proxy(*args, **kwargs):
        class R:
            status_code = 200
            headers = {"content-type": "application/json"}
            content = b'{"ok":true}'
        return R()

    monkeypatch.setattr("app.main.forward_request", fake_proxy)

    async def fake_refresh(self, targets, timeout_ms=1500):
        self.state.alive = {t: True for t in targets}

    def fake_pick(self, targets):
        return targets[0]

    monkeypatch.setattr("app.mirror_manager.MirrorManager.refresh", fake_refresh)
    monkeypatch.setattr("app.mirror_manager.MirrorManager.pick_first_alive", fake_pick)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/buy/any-prefix?utm_source=test")

    assert resp.status_code == 200
    assert resp.json()["ok"] is True


@pytest.mark.asyncio
async def test_payment_return_links_do_not_leak_origin_domain(monkeypatch):
    cfg = load_config("config/gateway.yml")
    origin_domain = cfg.raw["quick_setup"]["origin_domain"]
    public_domain = cfg.raw["project"]["public_domain"]
    app = create_app("config/gateway.yml")

    async def fake_proxy(*args, **kwargs):
        class R:
            status_code = 200
            headers = {"content-type": "application/json"}
            content = (
                f'{{"payment_url":"https://{origin_domain}/pay",'
                f'"return":"https%3A%2F%2F{origin_domain}%2Fbuy%2Fwl-lte"}}'
            ).encode("utf-8")

        return R()

    monkeypatch.setattr("app.main.forward_request", fake_proxy)

    async def fake_refresh(self, targets, timeout_ms=1500):
        self.state.alive = {t: True for t in targets}

    def fake_pick(self, targets):
        return targets[0]

    monkeypatch.setattr("app.mirror_manager.MirrorManager.refresh", fake_refresh)
    monkeypatch.setattr("app.mirror_manager.MirrorManager.pick_first_alive", fake_pick)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/api/payment/create")

    assert resp.status_code == 200
    body = resp.text
    assert origin_domain not in body
    assert public_domain in body
    assert f"https://{public_domain}/_r/" in body
    assert "https%3A%2F%2F" not in body


@pytest.mark.asyncio
async def test_payment_redirect_location_rewrites_origin_and_return_param(monkeypatch):
    cfg = load_config("config/gateway.yml")
    origin_domain = cfg.raw["quick_setup"]["origin_domain"]
    public_domain = cfg.raw["project"]["public_domain"]
    app = create_app("config/gateway.yml")

    async def fake_proxy(*args, **kwargs):
        class R:
            status_code = 302
            headers = {
                "content-type": "text/plain",
                "location": (
                    f"https://{origin_domain}/pay"
                    f"?return=https%3A%2F%2F{origin_domain}%2Fbuy%2Fwl-lte"
                ),
            }
            content = b""

        return R()

    monkeypatch.setattr("app.main.forward_request", fake_proxy)

    async def fake_refresh(self, targets, timeout_ms=1500):
        self.state.alive = {t: True for t in targets}

    def fake_pick(self, targets):
        return targets[0]

    monkeypatch.setattr("app.mirror_manager.MirrorManager.refresh", fake_refresh)
    monkeypatch.setattr("app.mirror_manager.MirrorManager.pick_first_alive", fake_pick)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False) as client:
        resp = await client.get("/api/payment/redirect")

    assert resp.status_code == 302
    location = resp.headers.get("location", "")
    assert origin_domain not in location
    assert public_domain in location
    assert f"return=https%3A%2F%2F{public_domain}%2Fbuy%2F" not in location
    assert "%2F_r%2F" in location


@pytest.mark.asyncio
async def test_return_unwrap_endpoint_redirects_to_public_buy_link():
    cfg = load_config("config/gateway.yml")
    public_domain = cfg.raw["project"]["public_domain"]
    app = create_app("config/gateway.yml")

    target = f"https://{public_domain}/buy/wl-lte"
    token = base64.urlsafe_b64encode(target.encode("utf-8")).decode("ascii").rstrip("=")

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test", follow_redirects=False) as client:
        resp = await client.get(f"/_r/{token}")

    assert resp.status_code == 302
    assert resp.headers["location"] == target
