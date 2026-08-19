-- -----------------------------------------------------------------------------
-- Filtering user-written text — App Store Guideline 1.2
-- -----------------------------------------------------------------------------
-- Prompt answers are the first user-generated content in DateNow. Guideline
-- 1.2 asks apps with UGC for four things: a way to filter objectionable
-- material, a way to report it, a way to block abusive users, and published
-- contact details. Reporting and blocking already exist (`reports`,
-- `blocked_users`, the report sheet). This is the filter.
--
-- Enforced by a trigger, not in the app: the check has to hold against a
-- tampered client, and the client is the least trustworthy place to decide
-- what may be stored.
--
-- Two families of pattern, for two different problems:
--   * contact details — email, phone, URLs, social handles. This is the
--     scam vector every dating product deals with: the pattern is to move
--     the target off-platform immediately, where there is no reporting and
--     no blocking. It is also the one class of text that can be caught
--     reliably by shape rather than by meaning.
--   * terms — slurs and explicit content. A list is a blunt instrument and
--     will never be complete; it lives in a table rather than in this file
--     so it can be extended without a migration, and reporting remains the
--     real backstop.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.moderation_blocklist (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  pattern    TEXT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('contact', 'term')),
  note       TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (pattern)
);

-- Read by the SECURITY DEFINER function below, never by the client: the
-- list of what is filtered is itself a roadmap for getting around it.
ALTER TABLE public.moderation_blocklist ENABLE ROW LEVEL SECURITY;

INSERT INTO public.moderation_blocklist (pattern, kind, note) VALUES
  ('[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}', 'contact', 'email'),
  ('(\+?[0-9][ .-]?){8,}',                              'contact', 'phone number'),
  ('(https?://|www\.)[^[:space:]]+',                    'contact', 'url'),
  ('(instagram|snapchat|snap|telegram|whatsapp|tiktok|onlyfans)', 'contact',
     'off-platform handle'),
  ('@[[:alnum:]._]{3,}',                                'contact', 'social handle')
ON CONFLICT (pattern) DO NOTHING;

-- -----------------------------------------------------------------------------
-- text_moderation_reason(text) — NULL when the text is acceptable, otherwise
-- the kind that rejected it. Returning the kind (not the pattern) lets the
-- app explain the refusal without publishing the list.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.text_moderation_reason(p_text TEXT)
RETURNS TEXT
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_kind TEXT;
BEGIN
  IF p_text IS NULL OR length(trim(p_text)) = 0 THEN
    RETURN NULL;
  END IF;

  SELECT kind INTO v_kind
    FROM public.moderation_blocklist
   WHERE p_text ~* pattern
   ORDER BY kind
   LIMIT 1;

  RETURN v_kind;
END;
$$;

-- -----------------------------------------------------------------------------
-- The trigger. Raises with the reason in the message so the client can map
-- it to a sentence a human understands, instead of surfacing a database
-- error the way the raw PostgrestException used to.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.enforce_prompt_moderation()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reason TEXT := public.text_moderation_reason(NEW.answer);
BEGIN
  IF v_reason IS NOT NULL THEN
    RAISE EXCEPTION 'prompt_rejected:%', v_reason
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_user_prompts_moderation ON public.user_prompts;
CREATE TRIGGER trg_user_prompts_moderation
  BEFORE INSERT OR UPDATE OF answer ON public.user_prompts
  FOR EACH ROW EXECUTE FUNCTION public.enforce_prompt_moderation();

NOTIFY pgrst, 'reload schema';
