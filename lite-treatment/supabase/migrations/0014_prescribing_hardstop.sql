-- ============================================================
-- Allergy Vigilance + Drug-Interaction hard-stop
-- Doctors previously had no e-prescribe screen at all. This adds
-- the actual prescribing path: server-side allergy check (hard
-- stop unless an override reason is given), interaction warning
-- carried through from the client's drug-interaction check, and
-- an audit trail for both.
-- ============================================================

alter table public.prescriptions add column allergy_override_reason text;

drop policy "prescriptions: doctor creates" on public.prescriptions;
create policy "prescriptions: insert via prescribe_medication only"
  on public.prescriptions for insert
  with check (false);

create or replace function public.prescribe_medication(
  p_patient_id uuid, p_medication_name text, p_dosage text, p_frequency text,
  p_reason text, p_interaction_warning text default null, p_allergy_override_reason text default null
)
returns public.prescriptions as $$
declare
  v_allergy_match text;
  v_rx public.prescriptions;
begin
  if public.current_role() not in ('doctor', 'admin') then
    raise exception 'Only a doctor can write a prescription';
  end if;

  select string_agg(name, ', ') into v_allergy_match
    from public.medical_entries
    where patient_id = p_patient_id
      and category = 'allergy'
      and (p_medication_name ilike '%' || name || '%' or name ilike '%' || p_medication_name || '%');

  if v_allergy_match is not null and coalesce(trim(p_allergy_override_reason), '') = '' then
    raise exception 'ALLERGY_HARD_STOP: patient has a recorded allergy to % — prescribing % requires an override reason', v_allergy_match, p_medication_name;
  end if;

  insert into public.prescriptions (patient_id, doctor_id, medication_name, dosage, frequency, reason, interaction_warning, allergy_override_reason, status)
  values (p_patient_id, auth.uid(), p_medication_name, p_dosage, p_frequency, p_reason, p_interaction_warning, p_allergy_override_reason, 'pending')
  returning * into v_rx;

  perform public.log_audit(
    case when v_allergy_match is not null then 'prescribe_with_allergy_override' else 'prescribe' end,
    'prescription', v_rx.id,
    jsonb_build_object('medication', p_medication_name, 'allergy_match', v_allergy_match, 'interaction_warning', p_interaction_warning)
  );

  return v_rx;
end;
$$ language plpgsql security definer;
