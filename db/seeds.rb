# Le pagine social gestite per la scuola. Si può rilanciare senza creare doppioni.
SocialPage.find_or_create_by!(url: "https://www.facebook.com/infanziacreola/") do |page|
  page.name = "Scuola dell'Infanzia Santa Maria Goretti Creola"
  page.platform = "facebook"
end
