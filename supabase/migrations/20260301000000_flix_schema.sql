-- Flix Cinema-Grade Production Schema for Lovable Cloud / Supabase
-- Auth, Multi-profile (up to 5, PIN), Continue Watching, Watchlist (My List), and Stream Resolver Cache

-- 1. Profiles Table
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    avatar_url TEXT NOT NULL DEFAULT 'assets/avatars/netflix_red.png',
    is_kids BOOLEAN NOT NULL DEFAULT FALSE,
    pin_hash TEXT,
    language TEXT NOT NULL DEFAULT 'en',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Index for user profiles query
CREATE INDEX IF NOT EXISTS idx_profiles_user_id ON public.profiles(user_id);

-- Enforce maximum of 5 profiles per user account
CREATE OR REPLACE FUNCTION public.check_profile_limit()
RETURNS TRIGGER AS $$
BEGIN
    IF (SELECT count(*) FROM public.profiles WHERE user_id = NEW.user_id) >= 5 THEN
        RAISE EXCEPTION 'A maximum of 5 profiles per user is allowed.';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_profile_limit ON public.profiles;
CREATE TRIGGER trg_check_profile_limit
    BEFORE INSERT ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.check_profile_limit();

-- Auto-update updated_at timestamp
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- 2. Watch Progress Table (Continue Watching)
CREATE TABLE IF NOT EXISTS public.watch_progress (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    tmdb_id INTEGER NOT NULL,
    media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
    season_number INTEGER NOT NULL DEFAULT 1,
    episode_number INTEGER NOT NULL DEFAULT 1,
    episode_title TEXT,
    title TEXT NOT NULL,
    poster_path TEXT,
    backdrop_path TEXT,
    position_seconds INTEGER NOT NULL DEFAULT 0,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    completed BOOLEAN NOT NULL DEFAULT FALSE,
    last_watched_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profile_watch_item UNIQUE (profile_id, tmdb_id, media_type, season_number, episode_number)
);

CREATE INDEX IF NOT EXISTS idx_watch_progress_profile ON public.watch_progress(profile_id, last_watched_at DESC);
CREATE INDEX IF NOT EXISTS idx_watch_progress_lookup ON public.watch_progress(profile_id, tmdb_id, media_type);

-- 3. Watchlist Table (My List)
CREATE TABLE IF NOT EXISTS public.watchlist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    profile_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    tmdb_id INTEGER NOT NULL,
    media_type TEXT NOT NULL CHECK (media_type IN ('movie', 'tv')),
    title TEXT NOT NULL,
    poster_path TEXT,
    backdrop_path TEXT,
    vote_average NUMERIC(3, 1),
    release_date TEXT,
    overview TEXT,
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profile_watchlist_item UNIQUE (profile_id, tmdb_id, media_type)
);

CREATE INDEX IF NOT EXISTS idx_watchlist_profile ON public.watchlist(profile_id, added_at DESC);

-- 4. Stream Cache Table
CREATE TABLE IF NOT EXISTS public.stream_cache (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cache_key TEXT UNIQUE NOT NULL,
    subject_id TEXT NOT NULL,
    title TEXT NOT NULL,
    media_type TEXT NOT NULL,
    season INTEGER,
    episode INTEGER,
    sources_json JSONB NOT NULL,
    captions_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '24 hours')
);

CREATE INDEX IF NOT EXISTS idx_stream_cache_key ON public.stream_cache(cache_key);
CREATE INDEX IF NOT EXISTS idx_stream_cache_expiry ON public.stream_cache(expires_at);

-- 5. Enable Row-Level Security (RLS) on all tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watch_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.watchlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stream_cache ENABLE ROW LEVEL SECURITY;

-- 6. RLS Policies
-- Profiles: Users manage only their own profiles
CREATE POLICY "Users can view their own profiles"
    ON public.profiles FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can create their own profiles"
    ON public.profiles FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own profiles"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own profiles"
    ON public.profiles FOR DELETE
    USING (auth.uid() = user_id);

-- Watch Progress: Users manage their own watch progress
CREATE POLICY "Users can view their own watch progress"
    ON public.watch_progress FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own watch progress"
    ON public.watch_progress FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own watch progress"
    ON public.watch_progress FOR UPDATE
    USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own watch progress"
    ON public.watch_progress FOR DELETE
    USING (auth.uid() = user_id);

-- Watchlist: Users manage their own watchlist
CREATE POLICY "Users can view their own watchlist"
    ON public.watchlist FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert into their own watchlist"
    ON public.watchlist FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete from their own watchlist"
    ON public.watchlist FOR DELETE
    USING (auth.uid() = user_id);

-- Stream Cache: All authenticated users can read cached streams; service_role or authenticated users can cache resolved streams
CREATE POLICY "Authenticated users can read stream cache"
    ON public.stream_cache FOR SELECT
    TO authenticated
    USING (expires_at > now());

CREATE POLICY "Authenticated users or functions can insert stream cache"
    ON public.stream_cache FOR INSERT
    TO authenticated
    WITH CHECK (true);

CREATE POLICY "Authenticated users or functions can update stream cache"
    ON public.stream_cache FOR UPDATE
    TO authenticated
    USING (true);
