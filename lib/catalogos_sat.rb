

class Catalogos
  require 'progressbar'
  require 'spreadsheet'
  require 'json'
  require 'net/http'

  REPLACEMENTS = { 
    'á' => "a",
    'é' => 'e',
    'í' => 'i',
    'ó' => 'o',
    'ú' => 'u',
    'ñ' => 'n',
    'ü' => 'u'
  }

  attr_accessor :local_eTag


  def initialize()
    @encoding_options = {
      :invalid   => :replace,     # Replace invalid byte sequences
      :replace => "",             # Use a blank for those replacements
      :universal_newline => true, # Always break lines with \n
      # For any character that isn't defined in ASCII, run this
      # code to find out how to replace it
      :fallback => lambda { |char|
        # If no replacement is specified, use an empty string
        REPLACEMENTS.fetch(char, "")
      },
    }
    @last_eTag = nil
  end


  def descargar(url_excel = "http://www.sat.gob.mx/informacion_fiscal/factura_electronica/Documents/catCFDI.xls")

    begin
      puts "Descargando archivo de Excel desde el SAT: #{url_excel}"
      url_excel = URI.parse(url_excel)
      bytesDescargados = 0      
  
      httpWork = Net::HTTP.start(url_excel.host) do
        |http|
        response = http.request_head(url_excel.path)
        totalSize = response['content-length'].to_i
        @local_eTag = response['etag'].split(",")[0]
        pbar = ProgressBar.create(:title => "Progreso:", :format => "%t %B %p%% %E")
        
        tempdir = Dir.tmpdir()
  
        File.open("#{tempdir}/catalogo.xls", "w") do |f|
          http.get(url_excel.path) do |str|
            bytesDescargados += str.length 
            relation = 100 * bytesDescargados / totalSize
            pbar.progress = relation
            f.write str          
          end
          pbar.finish()
   
        end
        puts "Descarga de Excel finalizada, guardado en #{tempdir}/catalogo.xls"      
      end
    rescue => e
      puts "Error al momento de descargar: #{e.message}"
      raise
    end

    return true

  end
  

  def procesar()

    begin
      Spreadsheet.client_encoding = 'UTF-8'
      
      # Checamos que el archivo de Excel exista previamente
      tempdir = Dir.tmpdir() 
      archivo = "#{tempdir}/catalogo.xls"
  
      
      raise 'El archivo de catálogos de Excel no existe o no ha sido descargado' if File.exist?(archivo) == false
      
      final_dir = "catalogosJSON"
      unless File.exist?("#{tempdir}/#{final_dir}")
        Dir.mkdir("#{tempdir}/#{final_dir}")
      end
  
  
      book = Spreadsheet.open(archivo)
      en_partes = false
      ultima_parte = false
      encabezados = Array.new
      renglones_json = nil
  
      # Recorremos todas las hojas/catálogos
      for i in 0..book.worksheets.count - 1 do
        hoja = book.worksheet i
      
        puts "\n\n----------------------------------------------"
        puts "Conviertiendo a JSON hoja #{hoja.name}..."
      
        # Manejamos la lectura de dos hojas separadas en partes, como la de Codigo Postal  
        if hoja.name.index("_Parte_") != nil
          en_partes = true
          ultima_parte = hoja.name.index("_Parte_2") != nil
          #TODO asume que hay como maximo 2 partes por archivo y que el identificador siempre es "_Parte_X"
        end 
  
        # Recorremos todos los renglones de la hoja de Excel
        j = 0
        hoja.each do |row|
          j += 1
          # Nos saltamos el primer renglon ya que siempre tiene la descripcion del catálogo, ejem "Catálogo de aduanas ..."
          next if j == 1
  
          break if row.to_s.index("Continúa en") != nil
          next if row.formats[0] == nil 
          # Nos saltamos renglones vacios
          next if row.to_s.index("[nil") != nil
          next if (row.to_s.index('["Fecha inicio de vigencia", "Fecha fin de vigencia", "Versión", "Revisión"]') != nil) && (ultima_parte == true)
          
          if row.formats[0].pattern_fg_color == :silver then
            if renglones_json.nil? then
              puts "Ignorando: #{row}"
              renglones_json = Array.new  
              encabezados = Array.new
            else   
              # Segundo encabezado, el "real"
              # Si ya tenemos encabezados nos salimos
              next if encabezados.count > 0  
              row.each do |col|
                # HACK: Para poder poner los valores correspondientes tomando en cuenta los encabezados
                if hoja.name == "c_TasaOCuota"
                  col = "maximo" if col == nil 
                  col = "minimo" if col == "c_TasaOCuota" 
                end
              
                next if col == nil
                # Si el nombre de la columna es el mismo que la hoja entonces es el "id" del catálogo
                col = "id" if hoja.name.index(col.to_s) != nil
                nombre = col.to_s
                # Convertimos a ASCII valido
                nombre = nombre.encode(Encoding.find('ASCII'), @encoding_options)
                # Convertimos la primer letra a minuscula
                nombre[0] = nombre[0].chr.downcase
                # La convertimos a camelCase para seguir la guia de JSON de Google:
                # https://google.github.io/styleguide/jsoncstyleguide.xml
                nombre = nombre.gsub(/\s(.)/) {|e| $1.upcase}
              
                encabezados << nombre
              end
            
              next
            end    
          end
        
          # Solo procedemos si ya hubo encabezados
          if  encabezados.count > 0 then
            #puts encabezados.to_s
            # Si la columna es tipo fecha nos la saltamos ya que es probable
            # que sea el valor de la fecha de modificacion del catálogo
            next if row[0].class == Date 
            
            hash_renglon = Hash.new
            for k in 0..encabezados.count - 1
              next if encabezados[k].to_s == ""  
              if row[k].instance_of?(Spreadsheet::Formula) == true
                  valor = row[k].value
              else                      
                  if row[k].class == Float 
                    if hoja.name == "c_Impuesto"
                      #puts "poniendo a tres cero"
                      valor = "%03d" % row[k].to_i
                    else
                      #puts "poniendo a 2 ceros: " + "%02d" % row[k].to_i
                      valor = "%02d" % row[k].to_i
                    end
                  else
                    valor = row[k].to_s
                  end
              end
          
              hash_renglon[encabezados[k]] = valor
            end
            renglones_json << hash_renglon
          end  
        end 
      
        # Guardamos el contenido JSON
        if !en_partes || ultima_parte then 
          puts "Escribiendo archivo JSON..."
          hoja.name.sub!(/(_Parte_\d+)$/, '') if ultima_parte
          File.open("#{tempdir}/#{final_dir}/#{hoja.name}.json","w") do |f|
            f.write(JSON.pretty_generate(renglones_json))
          end
          renglones_json = nil
          en_partes = false
          ultima_parte = false
          encabezados = Array.new
        end
      end
  
     
      
      puts "---------------------------------------------------------"
      puts "Se finalizó creacion de JSONs en directorio: #{tempdir}"

    rescue => e
      puts "Error en generacion de JSONs: #{e.message}"
      raise
    end

    return true

  end

  def nuevo_xls?(local_eTag = nil, url_excel = "http://www.sat.gob.mx/informacion_fiscal/factura_electronica/Documents/catCFDI.xls")
    local_eTag = @local_eTag if local_eTag.nil?
    url_excel = URI.parse(url_excel)
    new_eTag = nil

    httpWork = Net::HTTP.start(url_excel.host) do
      |http|
      response = http.request_head(url_excel.path)
      new_eTag = response['etag'].split(",")[0]
    end


    return new_eTag != local_eTag

  end

  def main(local_eTag = nil, url_excel = "http://www.sat.gob.mx/informacion_fiscal/factura_electronica/Documents/catCFDI.xls")
    
    if (nuevo_xls?(local_eTag, url_excel))
      descargar(url_excel)
      procesar()
    end
    
    return true
    
        
  end

end
  
