-- Sample hospitals for local dev / nearest-hospital testing
insert into public.hospitals (name, address, phone, emergency_24hr, location) values
  ('Lagos University Teaching Hospital (LUTH)', 'Ishaga Rd, Idi-Araba, Lagos', '+234-1-5851451', true, st_setsrid(st_makepoint(3.3733, 6.5175), 4326)::geography),
  ('Reddington Hospital, Victoria Island', '12 Idowu Martins St, Victoria Island, Lagos', '+234-1-2716000', true, st_setsrid(st_makepoint(3.4241, 6.4295), 4326)::geography),
  ('National Hospital Abuja', 'Central Business District, Abuja', '+234-9-4610500', true, st_setsrid(st_makepoint(7.4913, 9.0579), 4326)::geography),
  ('University College Hospital (UCH), Ibadan', 'Queen Elizabeth II Rd, Ibadan', '+234-2-2413300', true, st_setsrid(st_makepoint(3.9003, 7.4001), 4326)::geography),
  ('University of Calabar Teaching Hospital', 'Etta Agbor Rd, Calabar', '+234-87-234391', true, st_setsrid(st_makepoint(8.3238, 4.9526), 4326)::geography);
