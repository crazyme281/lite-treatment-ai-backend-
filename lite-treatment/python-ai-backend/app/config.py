import os

SUPABASE_URL = os.environ.get("SUPABASE_URL", "")
SUPABASE_ANON_KEY = os.environ.get("SUPABASE_ANON_KEY", "")

AI_API_KEY = os.environ.get("AI_API_KEY")
AI_API_URL = os.environ.get("AI_API_URL", "https://api.openai.com/v1/chat/completions")

# Model routing (P2 in the audit): cheap/fast model for simple
# questions, a stronger model for complex or flagged cases. Both
# independently overridable for non-OpenAI-compatible providers.
AI_MODEL_FAST = os.environ.get("AI_MODEL_FAST", "gpt-4o-mini")
AI_MODEL_REASONING = os.environ.get("AI_MODEL_REASONING", os.environ.get("AI_MODEL", "gpt-4o"))

AI_MAX_TOKENS = int(os.environ.get("AI_MAX_TOKENS", "900"))
ALLOWED_ORIGINS = [o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "*").split(",")]

# How many raw recent messages to keep verbatim before older ones get
# rolled into a stored summary instead of being resent forever.
RECENT_MESSAGE_WINDOW = int(os.environ.get("RECENT_MESSAGE_WINDOW", "10"))
