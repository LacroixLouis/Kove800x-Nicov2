-- Wize community: public road events, private authors, authenticated writes.
-- No rider position history, email or device identity is broadcast.
create schema if not exists wize_private;
revoke all on schema wize_private from public, anon;
grant usage on schema wize_private to authenticated;

create table public.wize_reports (
    id uuid primary key default gen_random_uuid(),
    kind text not null check (kind in ('accident','jam','roadworks','hazard','danger_zone')),
    latitude double precision not null check (latitude between -85 and 85),
    longitude double precision not null check (longitude between -180 and 180),
    bucket text not null,
    created_at timestamptz not null default now(),
    expires_at timestamptz not null default (now() + interval '60 minutes'),
    confirmations integer not null default 0,
    dismissals integer not null default 0
);
create index wize_reports_bucket_created on public.wize_reports(bucket,created_at desc);
create index wize_reports_expiry on public.wize_reports(expires_at);
alter table public.wize_reports enable row level security;
-- Events are shared with every authenticated rider, not owned private records.
-- Keeping expired tombstones readable lets Realtime propagate dismissals.
create policy wize_read_recent_events on public.wize_reports for select to authenticated
    using (created_at > (select now()) - interval '24 hours');
revoke all on public.wize_reports from public, anon, authenticated;
grant select on public.wize_reports to authenticated;

create table wize_private.authors (
    report_id uuid primary key references public.wize_reports(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);
create index wize_authors_user_time on wize_private.authors(user_id,created_at desc);
create table wize_private.votes (
    report_id uuid not null references public.wize_reports(id) on delete cascade,
    user_id uuid not null references auth.users(id) on delete cascade,
    confirmed boolean not null,
    updated_at timestamptz not null default now(),
    primary key (report_id,user_id)
);
create index wize_votes_user on wize_private.votes(user_id);
alter table wize_private.authors enable row level security;
alter table wize_private.votes enable row level security;
revoke all on wize_private.authors,wize_private.votes from public,anon,authenticated;

create function wize_private.publish_report(p_kind text,p_latitude double precision,p_longitude double precision)
returns public.wize_reports
language plpgsql security definer set search_path = '' as $$
declare
    actor uuid := auth.uid();
    result public.wize_reports;
    lat double precision := p_latitude;
    lon double precision := p_longitude;
begin
    if actor is null then raise exception 'Authentification requise' using errcode='42501'; end if;
    if p_kind is null or p_kind not in ('accident','jam','roadworks','hazard','danger_zone')
       or p_latitude is null or not (p_latitude between -85 and 85)
       or p_longitude is null or not (p_longitude between -180 and 180)
    then raise exception 'Signalement invalide' using errcode='22023'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text,0));
    if exists(select 1 from wize_private.authors where user_id=actor and created_at>now()-interval '30 seconds')
       or (select count(*) from wize_private.authors where user_id=actor and created_at>now()-interval '1 hour')>=20
    then raise exception 'Attends avant de publier un autre signalement' using errcode='P0001'; end if;
    -- A danger zone is an approximate area. Never publish the precise point.
    if p_kind='danger_zone' then
        lat := floor(p_latitude/0.04)*0.04+0.02;
        lon := floor(p_longitude/0.04)*0.04+0.02;
    end if;
    select r.* into result from public.wize_reports r
    where r.kind=p_kind and r.expires_at>now() and r.created_at>now()-interval '5 minutes'
      and abs(r.latitude-lat)<0.001 and abs(r.longitude-lon)<0.001
    order by r.created_at desc limit 1;
    if found then return result; end if;
    insert into public.wize_reports(kind,latitude,longitude,bucket,expires_at)
    values(p_kind,lat,lon,floor(lat*2)::integer::text||':'||floor(lon*2)::integer::text,
           now()+case when p_kind='roadworks' then interval '2 hours' else interval '1 hour' end)
    returning * into result;
    insert into wize_private.authors(report_id,user_id) values(result.id,actor);
    return result;
end;
$$;

create function wize_private.vote_report(p_report_id uuid,p_confirmed boolean,p_latitude double precision,p_longitude double precision)
returns public.wize_reports
language plpgsql security definer set search_path = '' as $$
declare
    actor uuid := auth.uid();
    result public.wize_reports;
    last_vote timestamptz;
    distance_m double precision;
begin
    if actor is null then raise exception 'Authentification requise' using errcode='42501'; end if;
    if p_confirmed is null or p_latitude is null or not(p_latitude between -85 and 85)
       or p_longitude is null or not(p_longitude between -180 and 180)
    then raise exception 'Position invalide' using errcode='22023'; end if;
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text,0));
    select * into result from public.wize_reports where id=p_report_id for update;
    if not found or result.expires_at<=now() then raise exception 'Ce signalement a expiré'; end if;
    if exists(select 1 from wize_private.authors where report_id=p_report_id and user_id=actor)
    then raise exception 'Un autre utilisateur doit confirmer ton signalement'; end if;
    distance_m := 111320*sqrt(power(result.latitude-p_latitude,2)+
                   power((result.longitude-p_longitude)*cos(radians(p_latitude)),2));
    if distance_m > (case when result.kind='danger_zone' then 5000 else 1000 end)
    then raise exception 'Rapproche-toi du signalement pour le confirmer'; end if;
    select updated_at into last_vote from wize_private.votes where report_id=p_report_id and user_id=actor;
    if last_vote>now()-interval '1 minute' then raise exception 'Confirmation déjà prise en compte'; end if;
    insert into wize_private.votes(report_id,user_id,confirmed) values(p_report_id,actor,p_confirmed)
    on conflict(report_id,user_id) do update set confirmed=excluded.confirmed,updated_at=now();
    update public.wize_reports r set
       confirmations=(select count(*)::integer from wize_private.votes v where v.report_id=r.id and v.confirmed),
       dismissals=(select count(*)::integer from wize_private.votes v where v.report_id=r.id and not v.confirmed)
    where r.id=p_report_id returning * into result;
    if result.dismissals>=3 and result.dismissals>=result.confirmations+2 then
       update public.wize_reports set expires_at=now() where id=p_report_id returning * into result;
    end if;
    return result;
end;
$$;

revoke all on function wize_private.publish_report(text,double precision,double precision) from public,anon;
revoke all on function wize_private.vote_report(uuid,boolean,double precision,double precision) from public,anon;
grant execute on function wize_private.publish_report(text,double precision,double precision) to authenticated;
grant execute on function wize_private.vote_report(uuid,boolean,double precision,double precision) to authenticated;

-- Exposed wrappers are SECURITY INVOKER; privileged code remains unexposed.
create function public.wize_publish_report(p_kind text,p_latitude double precision,p_longitude double precision)
returns public.wize_reports language sql security invoker set search_path = '' as $$
    select wize_private.publish_report(p_kind,p_latitude,p_longitude);
$$;
create function public.wize_vote_report(p_report_id uuid,p_confirmed boolean,p_latitude double precision,p_longitude double precision)
returns public.wize_reports language sql security invoker set search_path = '' as $$
    select wize_private.vote_report(p_report_id,p_confirmed,p_latitude,p_longitude);
$$;
revoke all on function public.wize_publish_report(text,double precision,double precision) from public,anon;
revoke all on function public.wize_vote_report(uuid,boolean,double precision,double precision) from public,anon;
grant execute on function public.wize_publish_report(text,double precision,double precision) to authenticated;
grant execute on function public.wize_vote_report(uuid,boolean,double precision,double precision) to authenticated;

alter publication supabase_realtime add table public.wize_reports;

create policy wize_private_authors_deny_clients on wize_private.authors for all to anon, authenticated using (false) with check (false);
create policy wize_private_votes_deny_clients on wize_private.votes for all to anon, authenticated using (false) with check (false);
