-- ==========================================
-- SOUL SYNC SUPABASE FULL DATABASE SCHEMA
-- ==========================================

-- 1. DROP EXISTING CONFLICTING TABLES (If re-running script)
DROP TABLE IF EXISTS public.diaries CASCADE;
DROP TABLE IF EXISTS public.profiles CASCADE;
DROP TABLE IF EXISTS public.couples CASCADE;

-- 2. CREATE COUPLES TABLE
-- Stores the link between User A and User B
CREATE TABLE public.couples (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 3. CREATE PROFILES TABLE
-- Extends auth.users, stores NIC, Name, and links to the couple
CREATE TABLE public.profiles (
  id uuid REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  name text NOT NULL,
  nic_number varchar(20) UNIQUE NOT NULL,
  couple_id uuid REFERENCES public.couples(id) ON DELETE SET NULL,
  couple_code varchar(10) UNIQUE,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- 4. ADD FOREIGN KEYS TO COUPLES (Circular linking)
-- Now that profiles exist, link the couple explicitly to the two users
ALTER TABLE public.couples ADD COLUMN user_a_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;
ALTER TABLE public.couples ADD COLUMN user_b_id uuid REFERENCES public.profiles(id) ON DELETE SET NULL;


-- 5. CREATE DIARIES TABLE
CREATE TABLE public.diaries (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  couple_id uuid REFERENCES public.couples(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  date date NOT NULL,
  content text NOT NULL,
  photo_urls text[], -- Array of strings for photo URLs
  is_revealed boolean DEFAULT false NOT NULL,
  request_to_reveal boolean DEFAULT false NOT NULL,
  is_editable boolean DEFAULT true NOT NULL,  -- For Immutability requirement
  created_at timestamp with time zone default timezone('utc'::text, now()) not null,
  -- Ensure only one entry per user per day
  UNIQUE(user_id, date)
);


-- 6. ENABLE ROW LEVEL SECURITY (RLS)
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.couples ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.diaries ENABLE ROW LEVEL SECURITY;

-- Security Policies: PROFILES
-- Users can view their own profile or their partner's profile
CREATE POLICY "Users can view own and partner profile" ON public.profiles
FOR SELECT USING (
  auth.uid() = id OR 
  couple_id IN (SELECT couple_id FROM public.profiles WHERE id = auth.uid())
);

-- Users can update their own profile (e.g. assigning a couple_id or generating an invite code)
CREATE POLICY "Users can update own profile" ON public.profiles
FOR UPDATE USING (auth.uid() = id);

-- Security Policies: COUPLES
-- Users can view their own couple record
CREATE POLICY "Users can view own couple record" ON public.couples
FOR SELECT USING (
  user_a_id = auth.uid() OR user_b_id = auth.uid()
);

-- Users can insert a new couple record when generating a code
CREATE POLICY "Users can create a couple record" ON public.couples
FOR INSERT WITH CHECK (
  user_a_id = auth.uid()
);

-- Users can update the couple record (User B joining via Couple Code)
CREATE POLICY "Users can join a couple record" ON public.couples
FOR UPDATE USING (
  user_b_id IS NULL -- Can only join if user B slot is empty
);


-- Security Policies: DIARIES
-- "Users can only type in their own tab."
CREATE POLICY "Users can insert own diaries" ON public.diaries
FOR INSERT WITH CHECK (
  user_id = auth.uid()
);

-- "Once entry is saved, Edit function is disabled."
CREATE POLICY "Users can update own editable diaries" ON public.diaries
FOR UPDATE USING (
  user_id = auth.uid() AND is_editable = true
);

-- "Content is hidden until Request to Read is sent and accepted."
-- This policy allows reading partner's row, but UI handles blurring content if !is_revealed
CREATE POLICY "Users can view partner diaries" ON public.diaries
FOR SELECT USING (
  user_id = auth.uid() OR 
  couple_id IN (SELECT couple_id FROM public.profiles WHERE id = auth.uid())
);


-- 7. DEFAULT SUPABASE AUTH TRIGGER
-- Automatically creates a profile row when a user signs up via Auth API.
-- (Note: you must pass `name` and `nic_number` in raw_user_meta_data during sign up)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, name, nic_number)
  VALUES (
    new.id, 
    new.raw_user_meta_data->>'name', 
    new.raw_user_meta_data->>'nic_number'
  );
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();

-- 8. STORAGE BUCKET setup (Optional if done via UI)
-- INSERT INTO storage.buckets (id, name, public) VALUES ('diary-photos', 'diary-photos', true);
