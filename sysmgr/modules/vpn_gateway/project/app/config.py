from copy import deepcopy
from dataclasses import dataclass
from pathlib import Path
import yaml


@dataclass
class RouteRule:
    name: str
    match: str
    upstream_pool: str


@dataclass
class RoutingConfig:
    preserve_query: bool
    preserve_path: bool
    routes: list[RouteRule]


@dataclass
class UpstreamPool:
    strategy: str
    targets: list[str]
    healthcheck: dict


@dataclass
class Config:
    raw: dict
    routing: RoutingConfig
    upstreams: dict[str, UpstreamPool]


def _normalize_quick_setup(raw: dict) -> dict:
    data = deepcopy(raw)
    quick = data.get("quick_setup", {})
    if not quick:
        return data

    public_domain = quick.get("public_domain")
    origin_domain = quick.get("origin_domain")
    origin_scheme = quick.get("origin_scheme", "https")
    default_offer = quick.get("default_offer")

    if public_domain:
        data.setdefault("project", {})["public_domain"] = public_domain

    if origin_domain:
        origin_base = f"{origin_scheme}://{origin_domain}"
        data.setdefault("upstreams", {}).setdefault("cabinet_pool", {}).setdefault("targets", [origin_base])
        data["upstreams"]["cabinet_pool"]["targets"] = [origin_base]

    if default_offer:
        data.setdefault("project", {})["default_target"] = default_offer
        landing_pages = data.setdefault("landing", {}).setdefault("pages", [])
        if landing_pages:
            landing_pages[0]["mirror_target"] = default_offer
        else:
            landing_pages.append({"path": "/", "mirror_target": default_offer})

    return data


def load_config(path: str) -> Config:
    cfg_path = Path(path)
    if not cfg_path.is_absolute():
        cfg_path = Path(__file__).resolve().parent.parent / path

    raw_data = yaml.safe_load(cfg_path.read_text(encoding="utf-8"))
    data = _normalize_quick_setup(raw_data)

    routes = [RouteRule(**route) for route in data["routing"]["routes"]]
    routing = RoutingConfig(
        preserve_query=data["routing"].get("preserve_query", True),
        preserve_path=data["routing"].get("preserve_path", True),
        routes=routes,
    )

    upstreams = {
        name: UpstreamPool(
            strategy=pool.get("strategy", "first_alive"),
            targets=pool.get("targets", []),
            healthcheck=pool.get("healthcheck", {}),
        )
        for name, pool in data["upstreams"].items()
    }

    return Config(raw=data, routing=routing, upstreams=upstreams)
