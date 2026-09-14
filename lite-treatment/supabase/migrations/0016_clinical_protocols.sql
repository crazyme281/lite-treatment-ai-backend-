-- ============================================================
-- Symptom-to-Protocol Guidance
-- ============================================================

create table public.clinical_protocols (
  id uuid primary key default uuid_generate_v4(),
  title text not null,
  keywords text not null,
  differential text,
  protocol_summary text,
  source_reference text,
  search_vector tsvector generated always as (
    to_tsvector('english', title || ' ' || keywords || ' ' || coalesce(differential, ''))
  ) stored,
  created_at timestamptz not null default now()
);

create index idx_clinical_protocols_search on public.clinical_protocols using gin(search_vector);

alter table public.clinical_protocols enable row level security;
create policy "clinical_protocols: readable by clinical staff"
  on public.clinical_protocols for select
  using (public.current_role() in ('doctor', 'nurse', 'student_doctor', 'radiologist', 'radiographer', 'pharmacist', 'admin'));
create policy "clinical_protocols: admin writes"
  on public.clinical_protocols for all
  using (public.current_role() = 'admin');

create or replace function public.search_protocols(p_query text)
returns setof public.clinical_protocols as $$
  select * from public.clinical_protocols
  where search_vector @@ plainto_tsquery('english', p_query)
  order by ts_rank(search_vector, plainto_tsquery('english', p_query)) desc
  limit 10;
$$ language sql stable;

insert into public.clinical_protocols (title, keywords, differential, protocol_summary, source_reference) values
('Acute Chest Pain', 'chest pain tight pressure crushing radiating arm jaw', 'ACS/MI, unstable angina, aortic dissection, PE, pericarditis, GERD, musculoskeletal', 'ECG within 10 min of presentation. Troponin at 0h/1h or 0h/3h. Aspirin 300mg if ACS suspected and no contraindication. Consider CT angiogram if dissection suspected (tearing pain, unequal pulses/BP).', 'ESC/ACC ACS guidelines (general reference)'),
('Shortness of Breath (Acute)', 'shortness of breath dyspnea breathless wheeze', 'Asthma/COPD exacerbation, PE, heart failure, pneumonia, pneumothorax, anaphylaxis', 'SpO2, ABG if severe. CXR. BNP/NT-proBNP if heart failure suspected. Consider Wells score for PE risk. Nebulized bronchodilator if wheeze present.', 'General emergency medicine reference'),
('Fever with Rash', 'fever rash spots petechiae rash child', 'Meningococcemia, measles, scarlet fever, drug reaction, viral exanthem', 'Assess for non-blanching rash — treat as possible meningococcemia until excluded (do not delay empirical antibiotics for blood cultures). Isolate if measles suspected.', 'General pediatric infectious disease reference'),
('Acute Abdominal Pain', 'abdominal pain stomach ache belly cramping', 'Appendicitis, cholecystitis, bowel obstruction, ectopic pregnancy, pancreatitis, perforated viscus', 'Full set of vitals, urinalysis, beta-hCG in any female of reproductive age. Lipase if epigastric. Erect CXR/AXR if perforation suspected. Analgesia should not be withheld pending diagnosis.', 'General surgery reference'),
('Severe Headache (Thunderclap)', 'headache severe sudden worst thunderclap', 'Subarachnoid hemorrhage, meningitis, venous sinus thrombosis, hypertensive emergency, migraine', 'Non-contrast CT head — if within 6h of onset and normal, LP generally not required for SAH exclusion per current evidence; use clinical judgement. Check BP. Assess for meningism.', 'General neurology/emergency reference'),
('Suspected Sepsis', 'sepsis infection fever tachycardia hypotension confusion', 'Sepsis, septic shock, SIRS from non-infectious cause', 'Sepsis Six within 1 hour: blood cultures, lactate, urine output, IV fluids, broad-spectrum antibiotics, oxygen. Reassess lactate at 2-4h.', 'Surviving Sepsis Campaign (general reference)');
