create or replace function public.create_radiology_case(
  p_patient_id uuid, p_assigned_doctor uuid, p_study_type text, p_priority case_priority default 'normal'
)
returns public.cases as $$
declare
  v_case public.cases;
begin
  if public.current_role() not in ('radiographer', 'admin') then
    raise exception 'Only a radiographer can submit a study';
  end if;
  if public.my_hospital_id() is null then
    raise exception 'You must be assigned to a hospital first';
  end if;

  insert into public.cases (patient_id, assigned_doctor, radiographer_id, hospital_id, study_type, priority, status)
  values (p_patient_id, p_assigned_doctor, auth.uid(), public.my_hospital_id(), p_study_type, p_priority, 'pending')
  returning * into v_case;

  perform public.log_audit('create_case', 'case', v_case.id, jsonb_build_object('study_type', p_study_type));

  return v_case;
end;
$$ language plpgsql security definer;
