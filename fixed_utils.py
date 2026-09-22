"""
Shared utilities (logging).
"""

import logging
import json
import os
import sys

from datetime import datetime, timezone

ENVIRONMENT = os.getenv("ENVIRONMENT", "dev").lower()

ENV_LOG_LEVEL_MAP = {
    "dev": logging.DEBUG,
    "sit": logging.INFO,
    "uat": logging.INFO,
    "prod": logging.ERROR
}

LOG_LEVEL = ENV_LOG_LEVEL_MAP.get(ENVIRONMENT, logging.INFO)

logging.basicConfig(level=LOG_LEVEL, force=True, format="%(message)s", stream=sys.stdout)

SERVICE_NAME = os.getenv("K_SERVICE", "unknown-service")

# Dedicated metric logger
metric_logger = logging.getLogger("metric_logger")
metric_logger.setLevel(logging.INFO)

if not metric_logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(logging.INFO)
    metric_logger.addHandler(handler)

metric_logger.propagate = False

def _log(level, message, **kwargs):
    """Logs a message with the specified level and additional context.
    Args:
        level (str): The log level.
        message (str): The log message.
        **kwargs: Additional context for the log message.
    """
    payload = {
        "severity": level.upper(),
        "message": message,
        "environment": ENVIRONMENT,
        "service": SERVICE_NAME,
        **kwargs
    }

    getattr(logging, level)(json.dumps(payload))

def _metric_log(level, message, **kwargs):
    """
    Logs a metric/event that should always be written
    regardless of the application's configured log level.
    """
    payload = {
        "severity": level.upper(),
        "log_type": "METRIC",
        "message": message,
        "environment": ENVIRONMENT,
        "service": SERVICE_NAME,
        **kwargs,
    }

    getattr(metric_logger, level)(json.dumps(payload))


def log_debug(message, **kwargs):
    """Logs a debug message with additional context."""
    _log("debug", message, **kwargs)


def log_info(message, **kwargs):
    """Logs an info message with additional context."""
    _log("info", message, **kwargs)


def log_warning(message, **kwargs):
    """Logs a warning message with additional context."""
    _log("warning", message, **kwargs)


def log_error(message, **kwargs):
    """Logs an error message with additional context."""
    _log("error", message, **kwargs)


def log_metric(message, **kwargs):
    """Logs a metric/event record."""
    _metric_log("info", message, **kwargs)


# Timestamp formatter to convert all timestamps to uniform UTC one
def format_timestamp(ts):
    """
    Parses various input formats and converts them uniformly to UTC ISO 8601: 
    YYYY-MM-DDTHH:MM:SSZ
    """
    if ts is None:
        return None
    
    # 1. Handle already existing datetime objects
    if isinstance(ts, datetime):
        # Convert to UTC timezone if offset-aware, otherwise assume UTC
        dt_utc = ts.astimezone(timezone.utc) if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
        return dt_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        
    # Normalize input to a stripped string
    ts_str = str(ts).strip()
    
    # 2. Handle Unix Epoch timestamps (e.g., 1787072757 or "1787072757.79")
    try:
        epoch_val = float(ts_str)
        # Ensure it's not a simple year string (like "2026") mistakenly treated as epoch
        if epoch_val > 100000000:  
            dt = datetime.fromtimestamp(epoch_val, tz=timezone.utc)
            return dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        pass

    # Normalize space separator to 'T' (e.g., "2026-08-19 17:05:57" -> "2026-08-19T17:05:57")
    ts_str = ts_str.replace(" ", "T")
    
    # 3. Handle high-precision fractional seconds (e.g., nanoseconds)
    # Python's fromisoformat() fails if there are more than 6 digits (microseconds)
    if '.' in ts_str:
        base, fraction_part = ts_str.split('.', 1)
        # Check if there is a timezone offset in the fractional part
        tz_char = ""
        for char in ('+', '-', 'Z'):
            if char in fraction_part:
                tz_char = char
                break
        
        if tz_char:
            fraction, tz_offset = fraction_part.split(tz_char, 1)
            tz_offset = tz_char + tz_offset
            # Truncate fractional digits to 6 (microseconds)
            ts_str = f"{base}.{fraction[:6]}{tz_offset}"
        else:
            # No timezone suffix, just truncate the fractional part
            ts_str = f"{base}.{fraction_part[:6]}"

    # 4. Handle standard ISO-8601 formatting with offsets
    try:
        # Standardize 'Z' to '+00:00' for backwards-compatible fromisoformat parsing
        if ts_str.endswith('Z'):
            ts_str = ts_str[:-1] + '+00:00'
            
        dt = datetime.fromisoformat(ts_str)
        # Convert any non-UTC offset to UTC
        return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        pass

    # 5. Fallback parsers for simpler standard formats
    fallbacks = (
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d"
    )
    for fmt in fallbacks:
        try:
            dt = datetime.strptime(ts_str, fmt)
            return dt.replace(tzinfo=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        except ValueError:
            continue

    # Return original string if all parsing attempts fail
    return str(ts)
