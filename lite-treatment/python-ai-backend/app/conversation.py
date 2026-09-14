"""
Three-layer memory (audit item 1): recent messages + a rolling
summary + structured patient context (handled in retrieval.py) —
instead of either "send nothing" (the original bug) or "send the
entire history forever" (doesn't scale, and the audit specifically
calls this out as a ceiling).
"""

from typing import Optional

from . import config


def get_recent_messages(client, conversation_id: Optional[str]) -> list[dict]:
    if not conversation_id:
        return []
    res = (
        client.table("ai_messages")
        .select("role, content")
        .eq("conversation_id", conversation_id)
        .order("created_at", desc=True)
        .limit(config.RECENT_MESSAGE_WINDOW)
        .execute()
    )
    return list(reversed(res.data or []))


def get_conversation_summary(client, conversation_id: Optional[str]) -> Optional[str]:
    if not conversation_id:
        return None
    res = client.table("ai_conversations").select("summary").eq("id", conversation_id).maybe_single().execute()
    return (res.data or {}).get("summary")


def maybe_update_summary(client, conversation_id: str, call_ai_fn) -> None:
    """If the conversation has grown past the recent-message window,
    roll everything older than that window into (or onto) a stored
    summary, so future requests don't need to resend it. `call_ai_fn`
    is injected (rather than imported) so this stays unit-testable
    without a real AI provider."""
    all_messages_res = (
        client.table("ai_messages")
        .select("role, content, created_at")
        .eq("conversation_id", conversation_id)
        .order("created_at")
        .execute()
    )
    all_messages = all_messages_res.data or []
    if len(all_messages) <= config.RECENT_MESSAGE_WINDOW:
        return

    to_summarize = all_messages[: len(all_messages) - config.RECENT_MESSAGE_WINDOW]
    existing_summary = get_conversation_summary(client, conversation_id) or ""

    transcript = "\n".join(f"{m['role']}: {m['content']}" for m in to_summarize)
    prompt = (
        (f"Existing summary so far:\n{existing_summary}\n\n" if existing_summary else "")
        + "Update the summary to also cover this earlier part of the conversation. "
        "Keep it factual and clinically relevant (symptoms mentioned, information already "
        "given, conclusions already reached) in 3-5 sentences:\n\n" + transcript
    )
    new_summary = call_ai_fn(prompt)
    client.table("ai_conversations").update({"summary": new_summary}).eq("id", conversation_id).execute()


def get_or_create_conversation(
    client, conversation_id: Optional[str], user_id: str, assistant_type: str,
    title: str, case_id: Optional[str] = None, patient_id: Optional[str] = None,
) -> str:
    if conversation_id:
        return conversation_id
    res = client.table("ai_conversations").insert({
        "user_id": user_id,
        "assistant_type": assistant_type,
        "related_case_id": case_id,
        "related_patient_id": patient_id,
        "title": title[:60],
    }).execute()
    return res.data[0]["id"]


def log_message(client, conversation_id: str, role: str, content: str, metadata: Optional[dict] = None):
    client.table("ai_messages").insert({
        "conversation_id": conversation_id,
        "role": role,
        "content": content,
        "metadata": metadata,
    }).execute()
