-- Only an explicit publication sends a local GPX to the Wukuluc community.
-- GPX bytes are preserved as base64, including extensions and waypoints.
create table public.wukuluc_routes (
    id uuid primary key,
    owner_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    name text not null check (char_length(btrim(name)) between 1 and 160),
    activity text not null check (activity in ('Moto trail','Enduro','Randonnée','VTT','Autre')),
    distance_km double precision not null check (distance_km between 0 and 100000),
    ascent_m double precision check (ascent_m between 0 and 1000000),
    duration_s double precision check (duration_s between 0 and 31536000),
    start_lat double precision not null check (start_lat between -90 and 90),
    start_lon double precision not null check (start_lon between -180 and 180),
    point_count integer not null check (point_count between 2 and 30000),
    gpx_base64 text not null check (octet_length(gpx_base64) between 1 and 13333336),
    created_at timestamptz not null default now()
);
create index wukuluc_routes_activity_created on public.wukuluc_routes(activity,created_at desc);
create index wukuluc_routes_owner_created on public.wukuluc_routes(owner_id,created_at desc);
create index wukuluc_routes_created on public.wukuluc_routes(created_at desc);
alter table public.wukuluc_routes enable row level security;
revoke all on public.wukuluc_routes from public,anon,authenticated;
grant select,insert,delete on public.wukuluc_routes to authenticated;
create policy wukuluc_published_routes_read on public.wukuluc_routes
    for select to authenticated using (true);
create policy wukuluc_publish_own_route on public.wukuluc_routes
    for insert to authenticated with check (owner_id = (select auth.uid()));
create policy wukuluc_remove_own_route on public.wukuluc_routes
    for delete to authenticated using (owner_id = (select auth.uid()));
create function public.wukuluc_limit_publications() returns trigger
language plpgsql security invoker set search_path = '' as $$
declare actor uuid := auth.uid();
begin
    if actor is null or new.owner_id <> actor then
        raise exception 'Authentification requise' using errcode='42501';
    end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text, 17));
    if (select count(*) from public.wukuluc_routes where owner_id=actor) >= 100
       or (select count(*) from public.wukuluc_routes
           where owner_id=actor and created_at > now()-interval '1 minute') >= 3 then
        raise exception 'Attends avant de partager un autre parcours' using errcode='P0001';
    end if;
    new.created_at := now();
    return new;
end;
$$;
revoke all on function public.wukuluc_limit_publications() from public,anon,authenticated;
create trigger wukuluc_limit_publications before insert on public.wukuluc_routes
    for each row execute function public.wukuluc_limit_publications();
