// Drug-interaction check called from the doctor's e-prescribe flow and
// the pharmacist's dispensing queue. Local reference table for now —
// swap fetchFromExternalApi() for a real call to RxNorm/OpenFDA/DrugBank
// when you have API access; the interface is already shaped for it.

import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { corsHeaders } from "../_shared/cors.ts";

const KNOWN_INTERACTIONS = [
  {
    pair: ["warfarin", "ibuprofen"],
    severity: "severe",
    message: "Warfarin + Ibuprofen (NSAID) — increased risk of bleeding.",
    alternatives: ["Acetaminophen (Paracetamol)", "Celecoxib"],
  },
  {
    pair: ["warfarin", "aspirin"],
    severity: "severe",
    message: "Warfarin + Aspirin — increased bleeding risk.",
    alternatives: ["Acetaminophen (Paracetamol)"],
  },
  {
    pair: ["linezolid", "maoi"],
    severity: "severe",
    message: "Linezolid + MAOI — risk of serotonin syndrome. Contraindicated.",
    alternatives: ["Ceftriaxone"],
  },
  {
    pair: ["metformin", "contrast dye"],
    severity: "moderate",
    message: "Metformin + Iodinated contrast — risk of lactic acidosis; hold metformin around imaging.",
    alternatives: [],
  },
];

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { medicationName, existingMedications = [] } = await req.json();
    const target = String(medicationName).toLowerCase();
    const existingLower = (existingMedications as string[]).map((m) => m.toLowerCase());

    let match = null;
    for (const entry of KNOWN_INTERACTIONS) {
      const [a, b] = entry.pair;
      const targetMatches = target.includes(a) || target.includes(b);
      const existingMatch = existingLower.some((m) => m.includes(a) || m.includes(b));
      if (targetMatches && existingMatch) {
        match = entry;
        break;
      }
    }

    return new Response(JSON.stringify({ interaction: match }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
