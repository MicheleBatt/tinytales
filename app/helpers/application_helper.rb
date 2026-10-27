module ApplicationHelper
  # La checklist dei lavori su sito e pagine social (pagina privata su claude.ai).
  # Si cambia con la variabile d'ambiente CHECKLIST_URL.
  CHECKLIST_URL = ENV.fetch("CHECKLIST_URL", "https://claude.ai/artifact/Tos8L3ykB7QKwQzQs2HGaK")

  def checklist_url = CHECKLIST_URL
end
