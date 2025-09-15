require "csv"
require "prestashop"
require 'active_support/inflector'
require "net/smtp"
require "mail"
require "erb"
require "resend"
require "dotenv"
require "chatgpt"
require "deepl"
require "rmagick"
require "i18n"

Dotenv.load()
# require_relative "deleter"
Resend.api_key = "re_WJntg4j3_Bt7i1GxsLXsdmsPSoZSvqPRF"
Prestashop::Client::Implementation.create "IKWHFE1ZKMJAQAGRBZ2NKIJQRIIEQMKL", 'https://www.montpellier4x4.com'


# Set DEEPL CREDENTIALS
DeepL.configure do |config|
  config.auth_key = "719ad2cc-14ff-4418-915f-f14933a98491"
  config.host = "https://api.deepl.com" # Default value is 'https://api.deepl.com'
end

ChatGPT.configure do |config|
  config.api_key = ENV['OPENAI_API_KEY']
  config.api_version = 'v1'
  config.default_engine = 'gpt-4.1'  # For chat
  config.request_timeout = 30
  config.max_retries = 3
  config.default_parameters = {
    max_tokens: 16,
    temperature: 1.0,
    top_p: 1.0,
    n: 1
  }
end

# Database connection details
host = 'localhost'       # MySQL host
username = 'image-deleter'        # MySQL username
password = 'zXv4VK3m87QDpdsB4ypC'    # MySQL password
database = 'prestashop'  # The name of the database

# Mail settings
# Mail.defaults do
#   delivery_method :smtp, { 
#     address:              'ssl0.ovh.net',
#     port:                 587,
#     user_name:            "informatique@montpellier4x4.com",
#     password:             "Montpellier4x4Info",
#     authentication:       'plain',
#     enable_starttls_auto: true
#   }
# end

Mail.defaults do
  delivery_method :smtp, { 
    address:              'smtp.gmail.com',
    port:                 587,
    user_name:            "lesalfistes@gmail.com",
    password:             "waio wwoa qabf ogbw",
    authentication:       'plain',
    enable_starttls_auto: true
  }
end


# Create a MySQL2 client
# CLIENT = Mysql2::Client.new(
#   host: host,
#   username: username,
#   password: password,
#   database: database
# )

def delete_image_by_id(item_id)
  # SQL query to delete the item
  query = "DELETE FROM ps_image WHERE id_image = ?"
  # Prepare and execute the query
  statement = ::CLIENT.prepare(query)
  puts "deleting image with id #{item_id}"
  statement.execute(item_id)
end


def find_no_weights
  no_weights = []
  our_products = Prestashop::Mapper::Product.all(filter: { active: 1})
  our_products.each do |p|
    product_info = Prestashop::Mapper::Product.find(p)
    no_weight = product_info[:weight].to_f == 0
    if no_weight 
      name = product_info.dig(:name, :language)[0][:val] rescue ""
      no_weights << "ID: #{product_info[:id]}, Ref: #{product_info[:reference]}, Nom: #{name}"
    end
  end
  if no_weights.length > 0
    text = ERB.new(<<-BLOCK).result(binding)
    <ul>#{no_weights.join("<li>")}}</ul>
  BLOCK
    mail = Mail.new do
      from    'lesalfistes@gmail.com'
      to      'contact@montpellier4x4.com'
      cc 'lesalfistes@gmail.com'
      subject "#{no_weights.length} produits actifs sans poids ont été trouvés"
    
      text_part do
        body text
      end
    
      html_part do
        content_type 'text/html; charset=UTF-8'
        body text
      end
    end
    mail.deliver!
  end
end


def optimize(text, desc_type)
  begin
    client = ChatGPT::Client.new(ENV['OPENAI_API_KEY'])
    char_limit = desc_type == "long" ? 21844 : 80000
    response = client.completions([{"role": "user", "content": "Please rephrase this text: #{text}. It cannot be longer than #{char_limit}. Please give me  just the result, I don't need text such as 'Here is a rephrased version within your limits'"}])
    response.dig("choices", 0, "message", "content")
  rescue => e
    puts "ChatGPT Failure: #{e.message}"
    Resend::Emails.send({
      "from": "tom@presta-smart.com",
      "to": "tom@tombrom.dev",
      "subject": "Erreur dans la méthode optimize impliquant chatGPT",
      "html":  "<span> This happened: #{e.message}</span>",
      "text": "text"
    })
  end
end
# References to delete:
# FileUtils.touch("sold_products.json")
# File.open("sold_products.json", "w+") do |f|
#   f.puts JSON.dump(sold_products)
# end
# DELETE OLD PRODUCTS
def delete_products(products, product_info, brand)
  deleted_products = 0
  products.uniq.each do |product_ref|
    # Get product details
    puts "product ref is #{product_ref}"
    next if product_ref == "product_sku"
    product = Prestashop::Client.read :products, nil, {filter: {reference: product_ref}}
    if product[:products].is_a?(String)
      puts "Unable to find this product, must have been deleted already"
      next 
    end
    # Get ID
    id = product.dig(:products, :product)[0].dig(:attr, :id) rescue ""
    if id == ""
      id = product.dig(:products, :product, :attr, :id) rescue ""
    end
    full_product = Prestashop::Mapper::Product.find(id)
    puts "Successfully retreived product id: #{id}"
    # Remove product or soft deletion, put it in "a supprimer" category
    begin
      current_categories = full_product.dig(:associations, :categories, :category)
      if current_categories.is_a?(Array)
        new_categories = current_categories << {id: 2961} 
      else
        # Make it an array
        new_categories = [current_categories, {id: 2961}]
      end
      Prestashop::Mapper::Product.update(id, associations: {categories: {attr: {nodetype: "category", api: "categories"}, category: new_categories}})
      # Prestashop::Client.delete :products, id
    rescue Prestashop::Api::RequestFailed => e
      mail = Mail.new do
        from    'lesalfistes@gmail.com'
        to      'contact@montpellier4x4.com'
        cc 'lesalfistes@gmail.com '
        subject "Erreur de suppression de l'article #{product_ref}"
      
        text_part do
          body "Erreur de suppression #{product_ref}"
        end
      
        html_part do
          content_type 'text/html; charset=UTF-8'
          body "<h2>L'article #{id} n'a pas pu être supprimé</h2><p>#{e.message}</p>"
        end
      end
      mail.deliver!
    end
    # FileUtils.touch("images.csv")
    # images.each do |img|
    #   image_array << img[:id]
    # end
    # CSV.open("images.csv", "a+") do |csv|
    #   csv << image_array
    # end
    # puts image_array
    puts "Successfully deleted product #{product_ref}"
    deleted_products += 1
    # Delete images
  end
  if deleted_products > 1
    text = ERB.new(<<-BLOCK).result(binding)
      <ul>#{product_info.join("<li>")}</ul>
    BLOCK
    Resend::Emails.send({
      "from": "tom@presta-smart.com",
      "to": "tom@tombrom.dev",
      "subject": "#{deleted_products} produits du catalogue #{brand} sont à supprimer.",
      "html":  "Vous pouvez les retrouver dans la catégorie 'A supprimer' à la racine" + text
    })
  end
end

def translate_products(products, language)
  puts "STARTING TRANSLATION OF FRONT RUNNER PRODUCTS"
  begin
    available_references_json = JSON.parse(File.open("catalogue-front-runner-FR-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
    available_references_json_en = JSON.parse(File.open("catalogue-front-runner-#{language}-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
  rescue JSON::ParserError => e
    Resend::Emails.send({
      "from": "tom@presta-smart.com",
      "to": "tom@tombrom.dev",
      "subject": "Error parsing Front Runner catalogue",
      "html": "<p>#{e.message}</p>"
    })
    if e.message == "unexpected token at 'Too many requests'"
      download_front_runner_catalogue(language, force: true)
      available_references_json = JSON.parse(File.open("catalogue-front-runner-FR-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
      available_references_json_en = JSON.parse(File.open("catalogue-front-runner-#{language}-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
    end
  end
  translated_products = 0
  products.each do |product|
    product_hash = available_references_json_en.find { |p| p["Code"] == product }
    product_hash_fr = available_references_json.find { |p| p["Code"] == product }
    # Get id
    product_id = Prestashop::Mapper::Product.find_by(filter: {reference: product})
    puts "PRODUCT ID: #{product_id}"
    if product_id
      # Get product info
      product_info = Prestashop::Mapper::Product.find(product_id)
      updated = false
      begin
        brand = product_hash["Brand"]
        fr_name = product_hash_fr["Description"]
        current_en_name = product_info[:name][:language][1][:val]
        new_name = product_hash["Description"]
        fr_short_desc = product_hash_fr["Narration"]
        current_en_short_desc =  product_info[:description_short][:language][1][:val]
        new_short_desc = product_hash["Narration"]
        fr_description = product_hash_fr["LongDescription"].gsub("\\n", "<br>") + "<br>" + product_hash_fr["Specification"].gsub("\\n", "<br>")
        current_en_description = product_info[:description][:language][1][:val]
        new_description = product_hash["LongDescription"].gsub("\\n", "<br>") + "<br>"  + product_hash["Specification"].gsub("\\n", "<br>")
        fr_meta_title = "Montpellier4x4 |" + " #{product_hash_fr["Brand"]} "+  product_hash_fr["Description"]
        en_meta_title = "Montpellier4x4 |" + " #{product_hash["Brand"]} "+  product_hash["Description"]
        fr_meta_description = product_hash_fr["Narration"][0...200]
        en_meta_description = product_hash["Narration"][0...200]
        translated = false
        if current_en_name == "" || current_en_name == fr_name
          puts "PRODUCT REF IS #{product}"
          puts "Current English Name is empty or same as French"
          unless current_en_name == new_name
            Prestashop::Mapper::Product.update(product_id, name: {language: [{attr: {id: 3}, val: new_name}, {attr: {id: 1}, val: fr_name}]}) 
            translated = true
          end
          translated_products += 1 unless translated
        end
        if current_en_short_desc == "" || current_en_short_desc == fr_short_desc
          puts "Current English Short Description is Empty or Same as French"
          Prestashop::Mapper::Product.update(product_id, description_short: {language: [{attr: {id: 3}, val: new_short_desc}, {attr: {id: 1}, val: fr_short_desc}]}) 
        end
        if current_en_description == "" || current_en_description == fr_description
          puts "Current English Description is empty or same as French"
          Prestashop::Mapper::Product.update(product_id, description: {language: [{attr: {id: 3}, val: new_description}, {attr: {id: 1}, val: fr_description}]}) 
        end
        Prestashop::Mapper::Product.update(product_id, meta_title: {language: [{attr: {id: 3}, val: en_meta_title}, {attr: {id: 1}, val: fr_meta_title}]}) 
        Prestashop::Mapper::Product.update(product_id, meta_description: {language: [{attr: {id: 3}, val: en_meta_description}, {attr: {id: 1}, val: fr_meta_description}]}) 
      rescue NoMethodError => e
        mail = Mail.new do
          from    'lesalfistes@gmail.com'
          to      't_bromehead@yahoo.fr'
          cc 't_bromehead@yahoo.fr'
          subject "MAJ Trans4: Erreur lors de la mise à jour de #{product["Name"]}"
        
          text_part do
            body "Détail de l'erreur #{e.message} pour le produit #{product_id} ref #{product}. "
          end
        
          html_part do
            content_type 'text/html; charset=UTF-8'
            body "<h2>Détail de l'erreur: #{e.message}  pour le produit #{product_id} ref #{product}.</h2>#{e.backtrace}<br />#{e.backtrace_locations}<br/>"
          end
        end
        mail.deliver!
      end
    end
  end
  if translated_products > 1
    mail = Mail.new do
      from    'informatique@montpellier4x4.com'
      to      'contact@montpellier4x4?.com'
      cc 't_bromehead@yahoo.fr'
      subject "MAJ Catalogue Trans4: #{translated_products} produits ont été traduits en Anglais"
    end
    mail.deliver!
  end
end

def download_files
  `curl -L 'https://api.trans4x4.com:8444/articles?itemsPerPage=5000' -o 'trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json'` unless File.exist?("trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json")
`curl -L 'https://api.trans4x4.com:8444/catalogues' -o 'trans4-categories-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json'` unless File.exist?("trans4-categories-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json")
`curl -L 'https://api.trans4x4.com:8444/marques' -o 'trans4-brands-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json'` unless File.exist?("trans4-brands-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json")
end

BRANDS = {
  "TERAFLEX" => "TF",
  "RIVAL" =>  "RI",
  "PEDDERS" => "PDS",
  "MAYHEM" => "OC",
  "BLACK RHINO" => "",
  "OC WHEELS" => "OC",
  "COME UP" => "WA",
  "CORE" => "CO",
  "AVM" => "AVM",
  "FUEL" => "D",
  "KAMPA" => "KP",
  "T-MAX" => "TM",
  "HOFMANN" => ""
}

def update_trans4
  download_files
  # brands = JSON.parse(File.open("trans4-brands-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
  # undistributed_brands = []
  # brands.each do |b|
  #   puts "Looking for brand #{b["nom"]}"
  #   brand = Prestashop::Mapper::Manufacturer.find_by(filter: {name: b["nom"]})
  #   unless brand
  #     brand = Prestashop::Mapper::Manufacturer.find_by(filter: {name: b["nom"].downcase}) || Prestashop::Mapper::Manufacturer.find_by(filter: {name: b["nom"].downcase.capitalize})
  #   end
  #   puts "Found Brand: #{b["nom"]} with ID #{brand}" if brand
  #   unless brand
  #     puts "Unable to find brand #{b["nom"]}"
  #     undistributed_brands << b["nom"]
  #   end
  # end
  # if undistributed_brands.length >= 1
  #   mail = Mail.new do
  #     from    'lesalfistes@gmail.com'
  #     to      't_bromehead@yahoo.fr'
  #     cc 'lesalfistes@gmail.com'
  #     subject "#{undistributed_brands.length} #{undistributed_brands.length > 1 ? "marques" : "marque"} du catalogue Trans4 non #{undistributed_brands.length > 1 ? "distribuées" : "distribuée"}"
  #     text = ERB.new(<<-BLOCK).result(binding)
  #       <ul>#{undistributed_brands.join("<li>")}}</ul>
  #     BLOCK
    
  #     text_part do
  #       body text
  #     end
    
  #     html_part do
  #       content_type 'text/html; charset=UTF-8'
  #       body text
  #     end
  #   end
  #   mail.deliver!
  # end
  trans4_products = JSON.parse(File.read("trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json"))
  # trans4_products = JSON.parse(File.read("trans4-stock-6-8-2025.json"))
  trans4_products.reject! { |p| p["marque"] == "FRONT RUNNER" }
  trans4_products.reject! { |p| p["marque"] == "DOMETIC" }
  trans4_products.each { |p| p["sku"].start_with?("RI2") ? p["sku"].gsub!("RI", "") : p["sku"] }
  products_length = trans4_products.length
  needs_price_update = 0
  trans4_products_we_have = 0
  products_needing_update_text = []
  products_needing_update = []
  product_needing_ref_update = 0
  pedders = Prestashop::Mapper::Product.all(filter: {id_manufacturer: 30})
  pedders.each do |pd|
    product = Prestashop::Mapper::Product.find(pd)
    ref = product[:reference]
    if ref.is_a?(String)
      next if ref.start_with?("PDS") || ref.start_with?("PED") || ref.start_with?("PL") || ref.empty?
      puts "Updating ref"
      Prestashop::Mapper::Product.update(pd, reference: "PDS#{ref}")
    end
  end
  trans4_products.each_with_index do |p, i| 
    puts "Looking up product #{i + 1 } of #{products_length}"
    our_product_id = Prestashop::Mapper::Product.find_by(filter: {reference: p["sku"]})
    if our_product_id
      puts "Found product without brand prefix"
    end
    unless our_product_id
      # puts "HAVING TO ADD RI IN FRONT OF REF"
      # find proper brand prefix
      brand_prefix = BRANDS[p["marque"]]
      our_product_id = Prestashop::Mapper::Product.find_by(filter: {reference: "#{brand_prefix}#{p['sku']}"})
      if our_product_id
        puts "Found product with brand prefix"
        # Update reference, product was found with the help of the prefix
        Prestashop::Mapper::Product.update(our_product_id, reference: "#{brand_prefix}#{p['sku']}")
        product_needing_ref_update += 1
      end
      # puts "Found Rival product: #{p['sku']}" if our_product_id
    end
    if our_product_id
      trans4_products_we_have += 1 if our_product_id
      our_product = Prestashop::Mapper::Product.find(our_product_id)
      their_price_ht = p["prix"]
      our_price_ht =  (our_product[:price].to_f).round(2)
      if p["sku"].start_with?("HSP")
        their_price_ht = their_price_ht * 2
      end
      # Compare prices
      same_price = our_price_ht == their_price_ht
      our_weight = our_product[:weight].to_f
      their_weight = p["poids"]
      unless our_weight == their_weight
        products_needing_update << {id: our_product_id, weight: their_weight}
        products_needing_update_text << "#{our_product[:reference]}, #{our_product[:name][:language][0][:val]}. Leur poids: <span style='font-size:16px'>#{their_weight}</span>, Notre poids: <span style='font-size:16px'>#{our_weight}</span>" rescue ""
      end
      unless same_price
        # Update price
        needs_price_update += 1
        puts "Product needs its price updated"
        products_needing_update << {id: our_product_id, price: their_price_ht}
        products_needing_update_text << "#{our_product[:reference]}, #{our_product[:name][:language][0][:val]}. Leur prix: <span style='font-size:16px'>#{their_price_ht}</span>, Notre prix: <span style='font-size:16px'>#{our_price_ht}</span>" rescue ""
      end
      # Check if images are missing
    end
  end
  # Resend::Emails.send({
  #   "from": "tom@presta-smart.com",
  #   "to": "tom@tombrom.dev",
  #   "subject": "Price update needed",
  #   "html":  "We have #{trans4_products_we_have} of Trans4 products on our website"
  # })
  # mail = Mail.new do
  #   from    'lesalfistes@gmail.com'
  #   to      'tom@tombrom.dev'
  #   cc 'lesalfistes@gmail.com'
  #   subject "#{product_needing_ref_update} produits Trans4 ont été mis à jour"
  # end
  # mail.deliver!
  # 2nd loop:
  # Iterate on our products and find the refs
  teraflex = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 176})
  core = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 158})
  come_up = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 54})
  pedders = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 30})
  black_rhino = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 120})
  avm = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 24})
  snug = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 152})
  kampa = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 160})
  tmax = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 89})
  lazer = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 76})
  hofman = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 48})
  rival =  Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 90})
  all_our_products = [*teraflex, *core, *come_up, *pedders, *black_rhino, *avm, *snug, *kampa, *tmax, *lazer, *hofman, *rival]
  nb_of_products = all_our_products.length
  all_our_trans4_products_in_their_catalogue = 0
  # needs_price_update_mtp4x4_to_trans4 = 0
  not_found = []
  found_products = []
  all_our_products.each_with_index do |o_p, i|
    our_product = Prestashop::Mapper::Product.find(o_p)
    product_brand = our_product[:manufacturer_name][:val]
    puts "Looking product #{i+1} of #{nb_of_products}"
    if our_product
      our_ref = our_product[:reference].to_s 
      next if our_ref.empty?
      # found_product = trans4_products.find { |p| p["sku"].include?(our_product[:reference].to_s) }
      found_product = trans4_products.find { |p| p["sku"] == our_product[:reference].to_s }
      # unless found_product
      #   found_product = trans4_products.find { |p| p["sku"].include?(our_product[:reference].to_s) }
      # end
      brand_prefix = BRANDS[product_brand.upcase]
      unless found_product
        found_product = trans4_products.find { |p| p["sku"] == "#{brand_prefix}#{our_product[:reference].to_s}" }
        unless found_product
          not_found << "#{our_product[:reference].to_s} : #{our_product[:name][:language][0][:val]}" rescue ""
          next
        end
      end
      all_our_trans4_products_in_their_catalogue += 1 if found_product
      found_products << "#{found_product['sku']} : #{found_product['name']}"
      their_price_ht = found_product["prix"]
      if our_product[:reference].to_s.start_with?("HSP")
        their_price_ht = their_price_ht * 2
      end
      our_price_ht = (our_product[:price].to_f).round(2)
        # Compare prices
      same_price = our_price_ht == their_price_ht
      our_weight = our_product[:weight].to_f
      their_weight = found_product["poids"]
      unless same_price
        # Update price
        # needs_price_update_mtp4x4_to_trans4 += 1
        products_needing_update << {id: our_product[:id], price: their_price_ht}
        products_needing_update_text << "#{our_product[:reference]}, #{our_product[:name][:language][0][:val]}. Leur prix: <span style='font-size:16px'>#{their_price_ht}</span>, Notre prix: <span style='font-size:16px'>#{our_price_ht}</span>" rescue ""
      end
      unless our_weight == their_weight
        products_needing_update << {id: our_product[:id], weight: their_weight}
        products_needing_update_text << "#{our_product[:reference]}, #{our_product[:name][:language][0][:val]}. Leur poids: <span style='font-size:16px'>#{their_weight}</span>, Notre poids: <span style='font-size:16px'>#{our_weight}</span>" rescue ""
      end
    end
  end
  if products_needing_update.length >= 1
    products_needing_update.uniq.each do |p|
      puts "updating product #{p}"
      if p.has_key?(:price)
        puts "price needs update"
        Prestashop::Mapper::Product.update(p[:id], price: p[:price])
      end
      if p.has_key?(:weight)
        puts "weight needs update"
        Prestashop::Mapper::Product.update(p[:id], weight: p[:weight])
        # Update feature value 11
        # Find weight if it already exists
        # fv = Prestashop::Mapper::ProductFeatureValue.find_by(id_feature: 11, value: p[:weight].to_s)
        # unless fv
        #   # Create it if it doesn't
        #   fv = Prestashop::Mapper::ProductFeatureValue.create(id_feature: 11, value: p[:weight].to_s, id_lang: 1)
        # end
        # Update Product to have this new feature
        # Prestashop::Mapper::Product.update(p[:id], )
      end
      our_product = Prestashop::Mapper::Product.find(p[:id])
      puts "found our product, checking to see whether it's active or not?"
      puts our_product[:active]
      if our_product[:active] == 0
        puts 'Activating this product'
        Prestashop::Mapper::Product.update(p[:id], active: 1)
      end
    end
    Resend::Emails.send({
      "from": "tom@presta-smart.com",
      "to": "tom@tombrom.dev",
      "cc": "t_bromehead@yahoo.fr",
      "subject": "#{products_needing_update.length} produits Trans4 ont été mis à jour",
      "html":  "#{products_needing_update_text.uniq.join("<li>")}",
      "text": "Some placeholder text here"
    })
  end
end

def update_rival
  rival = Prestashop::Mapper::Product.all(filter: {active: 1, id_manufacturer: 90})
  rival.each do |id|
    Prestashop::Mapper::Product.update(id, active: 1)
    product = Prestashop::Mapper::Product.find(id)
    unless product[:reference].start_with?("RI")
      puts "Updating reference to match that of Trans4"
      Prestashop::Mapper::Product.update(id, reference: "RI#{product[:reference]}")
    end
  end
end

# def create_trans4_categories
#   # Create
#   categories = JSON.parse(File.read("trans4-categories-11-3-2025.json"))
#   parent = Prestashop::Mapper::Category.find_by(filter: {name: "Trans4"})
#   categories.each do |c|
#     next if c["id"] == 1
#     exists = Prestashop::Mapper::Category.find_by({filter: {name: c["intitule"]}})
#     unless exists
#       if parent != 1
#         category = Prestashop::Mapper::Category.new({name: c["intitule"], id_lang: 1, id_parent: parent, link_rewrite: "", active: 0})
#       else
#         category = Prestashop::Mapper::Category.new({name: c["intitule"], id_lang: 1, link_rewrite: "", active: 0})
#       end
#       new_cat = category.create
#     end
#   end
#   # Map them
# end

def create_trans4_products
  download_files
  created_products = 0
  updated_products = 0
  new_product_info = []
  brand  = ""
  trans4_products = JSON.parse(File.read("trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json"))
  # trans4_products.keep_if { |p| %W(RIVAL TERAFLEX COME\ UP CORE PEDDERS AVM KAMPA T-MAX LAZER HOFMANN ).include?(p["marque"])}
  # trans4_products.keep_if { |p| %W(RIVAL TERAFLEX COME\ UP CORE PEDDERS AVM KAMPA T-MAX LAZER HOFMANN ).include?(p["marque"])}
  trans4_products.keep_if { |p| %W(HOFMANN).include?(p["marque"])}
  # trans4_products.reject! { |p| p["marque"] == "DOMETIC" }
  # trans4_products.each { |p| p["sku"].start_with?("RI2") ? p["sku"].gsub!("RI", "") : p["sku"] }
  products_that_need_creating = 0
  number_of_products = trans4_products.length
  trans4_products.each_with_index do |p, i|
    build_args = Hash.new
    # Look up product in JSON Hash
    product = Prestashop::Mapper::Product.find_by(filter: {reference: p["sku"]})
    puts "Looking up product #{i + 1} of #{number_of_products}"
    next if product
    products_that_need_creating += 1
    puts "Creating this product #{product}"
    # Check whether the product exits
    build_args["reference"] = p["sku"]
    build_args["price"] = p["prix"]
    build_args["weight"] = p["poids"].to_s
    brand = Prestashop::Mapper::Manufacturer.find_by(filter: {name: p["marque"]})
    name = ""
    if brand
      build_args["id_manufacturer"] = brand
    else
      Resend::Emails.send({
        "from": "tom@presta-smart.com",
        "to": "tom@tombrom.dev",
        "subject": "Création de marque nécessaire",
        "html":  "La marque #{p['marque']} doit être crée."
      })
    end
    build_args["name"] = p["name"].split(/ |\_/).map(&:capitalize).join(" ")
    build_args["name"].gsub!("-&gt","->")
    build_args["name"].gsub!("&gt", "+")
    if brand == 90
      # Translate the name as Rival products have their name in English
      begin
         response = DeepL.translate p["name"], 'EN', 'FR'
         build_args["name"] = response.text.capitalize.split(/ |\_/).map(&:capitalize).join(" ")
      rescue
        build_args["name"] = p["name"].split(/ |\_/).map(&:capitalize).join(" ")
      end
    end
    if brand == 30
      # Replace AMORT. and AVD/AVG etc with their full names
      if p["name"].include?("AMORT.")
        p["name"].gsub!("AMORT.", "AMORTISSEUR")
      end
      if p["name"].include?("AVD")
        p["name"].gsub!("AVD", "Avant Droit")
      end
      if p["name"].include?("Av")
        p["name"].gsub!("Av", "Avant")
      end
      if p["name"].include?("Ar")
        p["name"].gsub!("Ar", "Arrière")
      end
      if p["name"].include?("AVG")
        p["name"].gsub!("AVG", "Avant Gauche")
      end
      if p["name"].include?("ARD.")
        p["name"].gsub!("ARD", "Arrière Droit")
      end
      if p["name"].include?("ARG")
        p["name"].gsub!("ARG.", "Arrière Gauche")
      end
      if p["name"].include?(" av ")
        p["name"].gsub!(" av ", " avant ")
      end
      if p["name"].include?(" ar ")
        p["name"].gsub!(" ar ", " arrière ")
      end
      if p["name"].include?("Arr.")
        p["name"].gsub!("Arr.", "Arrière")
      end
      build_args["name"] = p["name"].split(/ |\_/).map(&:capitalize).join(" ")
    end
    if build_args["name"].include?("Spacer")
      build_args["name"].gsub!("Spacer", "Elargisseurs")
      build_args["name"].gsub!("(la paire)", "")
      build_args["price"] = build_args["price"] * 2
    end 
    build_args["meta_title"] = "Montpellier4x4 " + build_args["name"]
    if build_args["meta_title"].length < 70 && p["marque"].length < 10
      build_args["meta_title"] = "Montpellier4x4 " + build_args["name"] + " " + p["marque"]
    end
    starts_with_vowel = build_args["name"].downcase.start_with?("a", "e", "i", "o", "u")
    if starts_with_vowel
      build_args["meta_description"] = "Améliorez votre véhicule ou vos sorties tout terrain avec l'" + build_args["name"].downcase + " par " + p["marque"]
    else
      build_args["meta_description"] = "Améliorez votre véhicule ou vos sorties tout terrain avec " + build_args["name"] + " par " + p["marque"]
    end
    build_args["id_tax_rules_group"] = 9
    build_args["description_short"] = ""
    begin
      build_args["description"] = p["descriptions"][0]["1"].empty? ? "" : p["descriptions"][0]["1"]
    rescue NoMethodError
      build_args["description"] = ""
    end
    build_args["show_price"] = 1
    build_args["active"] = 0
    build_args["images"] = [p["image"], *p["images"]]
    puts "Product #{product} found " if product
    # # Get id or English language
    # Set defaults for product
    id_lang = Prestashop::Mapper::Language.find_by_iso_code('fr')
    build_args["id_lang"] = id_lang
    build_args.merge!({id_lang: id_lang})
    if p["cat1"].nil?
      category_id = 2931
    else
      category_id = Prestashop::Mapper::Category.find_by(filter: { name: "TRANS4-#{p["cat1"]["intitule"]}"})
    end
    unless category_id
      cat_name = "TRANS4-#{p["cat1"]["intitule"]}"
      category = Prestashop::Mapper::Category.new({name: cat_name, id_lang: id_lang, link_rewrite: cat_name, active: 0})
      new_cat = category.create
      category_id = new_cat[:id]
    end
    build_args["available_for_order"], build_args["available_now"] = 1, 1
    build_args["id_category_default"] = category_id
    # if category_id == 0
    #   raise Updater::UpdaterError.new(status, ref, )
    # end
    # Find weight attribute
    weight = Prestashop::Mapper::ProductFeature.find_in_cache("Poids", id_lang)
    weight_value = Prestashop::Mapper::ProductFeatureValue.find_in_cache(weight[:id], build_args["weight"], id_lang)
    unless weight_value
      temp_weight_value = Prestashop::Mapper::ProductFeatureValue.new(id_feature: weight[:id], value: build_args["weight"], id_lang: id_lang)
      weight_value = temp_weight_value.create
    end
    build_args["id_features"] = [
      ActiveSupport::HashWithIndifferentAccess.new({id_feature: weight[:id], id_feature_value: weight_value[:id]})
    ]
    draft_product = Prestashop::Mapper::Product.new(build_args)
    begin
      new_product = draft_product.create
    rescue Prestashop::Api::RequestFailed => e
      # Email error message
      puts e.message
    end
    if new_product[:id]
      info = "#{new_product[:id]}: #{}"
      new_product_info  << info
      puts "Product #{new_product[:name]} has been created"
      created_products += 1
      # Prestashop::Mapper::Product.update(new_product[:id], state: 1, active: 1)
      # Upload images:
      next unless build_args["images"] != [nil]
      build_args["images"].each_with_index do |url, i|
        image_name = ""
        image = Prestashop::Mapper::Image.new(resource: :products, id_resource: new_product[:id], source: url)
        if image
          puts "Uploading image for product #{new_product[:id]}"
          begin
            begin
              minimagick_image = Magick::Image.read(url).first
              minimagick = true
              minimagick_image.write("./#{image_name}-#{i}")
            rescue Magick::ImageMagickError
            end
            if minimagick_image.filesize > 500000
              # Resize image 
              minimagic = true
              resized = minimagick_image.resize_to_fit(800, 600)
              3.times { puts "---------------" }
              puts "Overweight Image"
              3.times { puts "---------------" }
              image_name = new_product[:name][:language][0][:val].split(" ").join("-").downcase rescue "1"
              image_name.gsub!("/", "")
              image_name.gsub!("--", "-")
              image_name = I18n.transliterate(image_name)
              resized.write("./#{image_name}-#{i}")
              if resized.filesize > 500000
                # Resize further
                resized = resized.resize_to_fit(600, 450)
                resized.write("./#{image_name}-#{i}")
              end
            end
            if minimagic
              image = Prestashop::Mapper::Image.new(resource: :products, id_resource: new_product[:id], source: "./#{image_name}-#{i}")
            else
              puts "Not using minimagic to resize it"
              image = Prestashop::Mapper::Image.new(resource: :products, id_resource: new_product[:id], source: url)
            end
            image.upload
            FileUtils.rm("./#{image_name}-#{i}") if File.exist?("#{image_name}-#{i}")
          rescue Prestashop::Api::RequestFailed => e
            # Resend::Emails.send({
            #   "from": "tom@presta-smart.com",
            #   "to": "tom@tombrom.dev",
            #   "subject": "Erreur Prestashop lors de l'import du produit #{build_args["reference"]}",
            #   "html":  e.message
            # })
          rescue URI::InvalidURIError => e
            # Resend::Emails.send({
            #   "from": "tom@presta-smart.com",
            #   "to": "web@trans4x4.com",
            #   "cc": "tom@tombrom.dev",
            #   "subject": "Erreur d'url pour une de vos images",
            #   "html":  e.message
            # })
          end
        end
      end
    else
      puts "Skipping this product, already exists"
      next
    end
  end
  if products_that_need_creating >= 1
    mail = Mail.new do
      from    'lesalfistes@gmail.com'
      to      'tom@tombrom.dev'
      subject "Catalogue Trans4: #{products_that_need_creating} produits à créer"
    
      text_part do
        body ""
      end
    
      html_part do
        content_type 'text/html; charset=UTF-8'
        body ""
      end
    end
    mail.deliver!
  end
  if created_products >= 1
    mail = Mail.new do
      from    'lesalfistes@gmail.com'
      cc 'tom@tombrom.dev'
      subject "Création de #{created_products} produits du catalogue Trans4"
    
      text_part do
        body ""
      end
    
      html_part do
        content_type 'text/html; charset=UTF-8'
        body "Produits rangés dans Accueil > Trans4"
      end
    end
    mail.deliver!
    # translate_products(new_products)
  end

end

def obsolete_trans4
  download_files
  brands = JSON.parse(File.open("trans4-brands-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
  available_products =JSON.parse(File.open("trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
  brands.reject!{|b| ["FRONT RUNNER", "DOMETIC"].include?(b["nom"])}
  brands.each do |b|
    not_found = []
    manufacturer_our_side = Prestashop::Mapper::Manufacturer.find_by(filter: {name: b["nom"]})
    if manufacturer_our_side
      # Check products on our site from that manufacturer
      products_from_that_manufacturer_our_side = Prestashop::Mapper::Product.all(filter: {id_manufacturer: manufacturer_our_side, active: 1})
      next if products_from_that_manufacturer_our_side.nil?
      products_from_that_manufacturer_our_side.each do |p|
        product_hash = Prestashop::Mapper::Product.find(p)
        product_ref = product_hash[:reference]
        # Look up reference in available products
        product_on_their_side = available_products.find{ |p| p["sku"] == product_ref }
        if manufacturer_our_side == 90 && product_on_their_side.nil?
          product_on_their_side = available_products.find{ |p| p["sku"] == "RI#{product_ref}" }
        end
        if manufacturer_our_side == 30 && product_on_their_side.nil?
          product_on_their_side = available_products.find{ |p| p["sku"] == "PDS#{product_ref}" }
        end
        if product_on_their_side
        else  
          ref = product_hash[:name][:language][0][:val] rescue product_hash[:name][:language][:val]
          not_found << ["#{product_ref}: #{ref}"]
          current_categories = product_hash.dig(:associations, :categories, :category)
          if current_categories.is_a?(Array)
            new_categories = current_categories << {id: 2961} 
          else
            # Make it an array
            new_categories = [current_categories, {id: 2961}]
          end
          Prestashop::Mapper::Product.update(p, associations: {categories: {attr: {nodetype: "category", api: "categories"}, category: new_categories}})
        end
      end
    end
    # Resend::Emails.send({
    #   "from": "tom@presta-smart.com",
    #   "to": "tom@tombrom.dev",
    #   "subject": "Catalogue Trans4: #{not_found.length} produits #{b["nom"]} potentiellement obsolètes",
    #   "html":  not_found.join("<li>"),
    #   "text": 
    # })
    if not_found.length > 1
      mail = Mail.new do
        from    'lesalfistes@gmail.com'
        to      'tom@tombrom.dev'
        subject "Catalogue Trans4: #{not_found.length} produits #{b["nom"]} potentiellement obsolètes"
      
        text_part do
          body not_found.join("<li>")
        end
      
        html_part do
          content_type 'text/html; charset=UTF-8'
          body not_found.join("<li>")
        end
      end
      mail.deliver!
    end
  end
end

def update_stock_levels
  download_files
  available_products =JSON.parse(File.open("trans4-stock-#{Time.now.day}-#{Time.now.month}-#{Time.now.year}.json").read)
  number_of_products = available_products.length
  number_of_products_updated = 0
  available_products.each_with_index do |ap, i|
    product_id = Prestashop::Mapper::Product.find_by(filter: {reference: ap["sku"]})
    puts "Looking up product #{i + 1} of #{number_of_products}"
    next if product_id.nil?
    product_info =  Prestashop::Mapper::Product.find(product_id)
    stock_available_id = Prestashop::Mapper::StockAvailable.find_by(filter: {id_product: product_id})
    next unless stock_available_id
    stock_available_object = Prestashop::Mapper::StockAvailable.find(stock_available_id)
    begin
      #Update Available Quantity
      # If quantity is available from supplier
      case  ap["stock"].downcase
      when "true"
        quantity = [4, 7, 9, 11, 5, 8, 3, 6, 10].sample
      when "false"
        quantity = 0
      when "NC"
        quantity = 3
      else
        quantity =  ap["stock"].to_i
      end
      unless quantity == stock_available_object[:quantity]
        puts "Updating quantity from #{stock_available_object[:quantity]} to #{quantity}"
        Prestashop::Mapper::StockAvailable.update(stock_available_id, quantity: quantity)
      end
      if stock_available_object[:quantity] == 30
        Prestashop::Mapper::StockAvailable.update(stock_available_id, quantity: quantity)
      end
      number_of_products_updated += 1
    rescue StandardError => e
      Resend::Emails.send({
        "from": "tom@presta-smart.com",
        "to": "tom@tombrom.dev",
        "subject": "Erreur lors de la MAJ du stock Trans4",
        "html":  "<span>This happened #{e.message}</span>",
      })
    end
  end
  Resend::Emails.send({
    "from": "tom@presta-smart.com",
    "to": "tom@tombrom.dev",
    "subject": "Stock Trans4: MAJ #{number_of_products_updated} produits. ",
    "html":  "#{number_of_products_updated} produits sur #{number_of_products} ont vu leur stock mis à jour"
  })
end



# rescue URI::InvalidURIError
#      "https://api.trans4x4.com:8444/images/PDS280106/ 1.png"

# create_trans4_categories
begin
  update_trans4
  # create_trans4_products
  obsolete_trans4
  # create_b2b_categories
  update_stock_levels
ensure
  [Dir["*.csv"], Dir["*.json"]].flatten.each { |f| FileUtils.rm(f)}
end