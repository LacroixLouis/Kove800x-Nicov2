-- Transactional integration test: no test accounts or routes survive rollback.
begin;
select set_config('wukuluc.test_actor', gen_random_uuid()::text, true);
select set_config('wukuluc.test_peer', gen_random_uuid()::text, true);
select set_config('wukuluc.test_route', gen_random_uuid()::text, true);
insert into auth.users(id) values
    (current_setting('wukuluc.test_actor')::uuid),
    (current_setting('wukuluc.test_peer')::uuid);
set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('wukuluc.test_actor'), true);
insert into public.wukuluc_routes(id,name,activity,distance_km,start_lat,start_lon,point_count,gpx_base64)
values(current_setting('wukuluc.test_route')::uuid,'Wukuluc test','Moto trail',1.2,46,5,2,
       encode(convert_to('<gpx><trk><trkseg><trkpt lat="46" lon="5"/><trkpt lat="46.01" lon="5"/></trkseg></trk></gpx>','UTF8'),'base64'));
do $$
begin
    if (select owner_id from public.wukuluc_routes where id=current_setting('wukuluc.test_route')::uuid)
       <> current_setting('wukuluc.test_actor')::uuid then raise exception 'Owner default failed'; end if;
end $$;
select set_config('request.jwt.claim.sub', current_setting('wukuluc.test_peer'), true);
do $$
declare removed integer;
begin
    if not exists(select 1 from public.wukuluc_routes where id=current_setting('wukuluc.test_route')::uuid)
       then raise exception 'Peer cannot read published GPX'; end if;
    delete from public.wukuluc_routes where id=current_setting('wukuluc.test_route')::uuid;
    get diagnostics removed = row_count;
    if removed <> 0 then raise exception 'Peer deleted another owner route'; end if;
    begin
        insert into public.wukuluc_routes(id,owner_id,name,activity,distance_km,start_lat,start_lon,point_count,gpx_base64)
        values(gen_random_uuid(),current_setting('wukuluc.test_actor')::uuid,'Spoof','VTT',1,46,5,2,'PHg+');
        raise exception 'Spoofed owner accepted';
    exception when insufficient_privilege then null;
    end;
    begin
        update public.wukuluc_routes set name='Hijacked' where id=current_setting('wukuluc.test_route')::uuid;
        raise exception 'Route update accepted';
    exception when insufficient_privilege then null;
    end;
end $$;
select set_config('request.jwt.claim.sub', current_setting('wukuluc.test_actor'), true);
do $$
declare counter integer;
begin
    for counter in 1..2 loop
        insert into public.wukuluc_routes(id,name,activity,distance_km,start_lat,start_lon,point_count,gpx_base64)
        values(gen_random_uuid(),'Quota test','Moto trail',1,46,5,2,'PHg+');
    end loop;
    begin
        insert into public.wukuluc_routes(id,name,activity,distance_km,start_lat,start_lon,point_count,gpx_base64)
        values(gen_random_uuid(),'Fourth route','Moto trail',1,46,5,2,'PHg+');
        raise exception 'Publication quota bypassed';
    exception when raise_exception then
        if sqlerrm = 'Publication quota bypassed' then raise; end if;
    end;
    delete from public.wukuluc_routes where id=current_setting('wukuluc.test_route')::uuid;
    if exists(select 1 from public.wukuluc_routes where id=current_setting('wukuluc.test_route')::uuid)
       then raise exception 'Owner withdrawal failed'; end if;
end $$;
reset role;
set local role anon;
do $$
begin
    begin
        perform 1 from public.wukuluc_routes;
        raise exception 'Unauthenticated access accepted';
    exception when insufficient_privilege then null;
    end;
end $$;
reset role;
rollback;
select 'owner publication, peer read, owner-only withdrawal, spoof rejection, publication quota and anonymous denial passed; all fixtures rolled back' as verification;
