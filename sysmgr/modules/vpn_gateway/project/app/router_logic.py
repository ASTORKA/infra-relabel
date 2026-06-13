import fnmatch


def match_route(path: str, routes: list[dict]) -> dict:
    for route in routes:
        pattern = route["match"]
        if fnmatch.fnmatch(path, pattern):
            return route
    raise ValueError(f"Маршрут не найден для пути: {path}")
