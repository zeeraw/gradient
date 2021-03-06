module Gradient
  class GRD

    COLOR_TERMS = %w(Cyn Mgnt Ylw Blck Rd Grn Bl H Strt Brgh)
    PARSE_METHODS = {
      "patt" => :parse_patt,
      "desc" => :parse_desc,
      "VlLs" => :parse_vlls,
      "TEXT" => :parse_text,
      "Objc" => :parse_objc,
      "UntF" => :parse_untf,
      "bool" => :parse_bool,
      "long" => :parse_long,
      "doub" => :parse_doub,
      "enum" => :parse_enum,
      "tdta" => :parse_tdta,
    }

    attr_reader :maps

    class << self

      def parse(string_buffer)
        new.tap do |parser|
          parser.parse(string_buffer)
        end.maps
      end

      def read(file)
        new.tap do |parser|
          File.open(file, "r") do |file|
            parser.parse(file.read)
          end
        end.maps
      end

      def open(file)
        read(file)
      end

    end

    def initialize
      @maps = {}

      @gradient_names = []
      @color_gradients = []
      @transparency_gradients = []

      @current_object_name = ""
      @current_color_gradient = []
      @current_transparency_gradient = []
      @current_color = {}
      @current_transparency = {}

      @shift = 0
    end

    def parse(buffer)
      @buffer = buffer
      @offset = 28
      parse_entry while @offset < @buffer.length
      flush_current_gradient

      color_gradients = @color_gradients.map do |gradient|
        clean_color_gradient(gradient).map do |color_step|
          Gradient::ColorPoint.new(*color_step)
        end
      end

      transparency_gradients = @transparency_gradients.map do |gradient|
        clean_transparency_gradient(gradient).map do |transparency_step|
          Gradient::OpacityPoint.new(*transparency_step)
        end
      end

      gradients = color_gradients.zip(transparency_gradients).map do |color_points|
        Gradient::Map.new(Gradient::PointMerger.new(*color_points).call)
      end

      @maps = Hash[ @gradient_names.zip(gradients) ]
    end

    private def clean_gradient(steps)
      locations = steps.map { |g| g.fetch("Lctn", 0.0) }
      min_location = locations.min
      max_location = locations.max

      locations = locations.map do |location|
        ((location - min_location) * (1.0 / (max_location - min_location))).round(3)
      end
    end

    private def clean_color_gradient(steps)
      locations = clean_gradient(steps)
      colors = steps.map do |step|
        convert_to_color(step)
      end
      locations.zip(colors)
    end

    private def clean_transparency_gradient(steps)
      locations = clean_gradient(steps)
      transparencies = steps.map do |step|
        convert_to_opacity(step)
      end
      locations.zip(transparencies)
    end

    private def convert_to_opacity(opacity_data)
      opacity_data["Opct"]
    end

    private def convert_to_color(color_data)
      case format = color_data["palette"]
      when "CMYC" then Color::CMYK.from_percent(*color_data.values_at("Cyn", "Mgnt", "Ylw", "Blck").map(&:round)).to_rgb
      when "RGBC" then Color::RGB.new(*color_data.values_at("Rd", "Grn", "Bl").map(&:round))
      when "HSBC"
        h = color_data.fetch("H")
        s = color_data.fetch("Strt") / 100.0
        l = color_data.fetch("Brgh") / 100.0
        Color::HSL.from_fraction(h, s, l).to_rgb
      else
        raise NotImplementedError.new("The color #{format} is not supported")
      end
    end

    # Unpack 8 bytes IEEE 754 value to floating point number
    private def current_float_slice
      @buffer.slice(@offset, 8).unpack("G").first
    end

    private def current_slice_length
      current_slice.unpack("L>").first
    end

    private def current_slice(length=4)
      @buffer.slice(@offset, length)
    end

    private def continue!(steps=4)
      @offset += steps
    end

    private def upshift!
      @shift += 4
    end

    private def downshift!
      @shift -= 4
    end

    private def log(name, type, *args)
      puts "#{Array.new(@shift, " ").join}#{name}(#{type}) #{ Array(args).map(&:to_s).reject(&:empty?).join(", ") }" if ENV["ENABLE_LOG"]
    end

    private def send_parse_method(type, name, rollback)
      if parse_method = PARSE_METHODS.fetch(type, nil)
        send(parse_method, name)
      else
        parse_unknown(name, rollback)
      end
    end

    private def parse_entry
      length = current_slice_length
      length = 4 if length.zero?
      length = 4 if length > 256

      rollback = @offset

      continue!

      name = current_slice
      continue!(length)

      type = current_slice
      continue!

      send_parse_method(type, name, rollback)
    end

    private def flush_current_gradient
      flush_current_color
      flush_current_transparency
      @color_gradients << @current_color_gradient if @current_color_gradient.any?
      @transparency_gradients << @current_transparency_gradient if @current_transparency_gradient.any?
      @current_color_gradient = []
      @current_transparency_gradient = []
    end

    private def flush_current_color
      @current_color_gradient << @current_color if @current_color.any?
      @current_color = {}
    end

    private def flush_current_transparency
      @current_transparency_gradient << @current_transparency if @current_transparency.any?
      @current_transparency = {}
    end

    private def parse_patt(name)
      # TODO: Figure out exactly what this is and implement it.
      log(name, "patt")
    end

    private def parse_desc(name)
      size = current_slice_length
      log(name, "desc", size)
      continue!(26)
    end

    private def parse_vlls(name)
      size = current_slice_length
      continue!
      log(name, "vlls", size)
      upshift!

      size.times do |i|
        type = current_slice
        continue!

        begin
          if parse_method = PARSE_METHODS.fetch(type.strip, nil)
            send(parse_method, name)
          end
        rescue ArgumentError => e
        end
      end

      downshift!
    end

    private def parse_text(name)
      size = current_slice_length
      characters = []

      (0..size).each_with_index do |string, idx|
        a = @offset + 4 + idx * 2 + 1
        b = @offset + 4 + idx * 2 + 2
        characters << @buffer[a...b]
      end

      text = characters.join

      log(name, "text", size, text)

      if @current_object_name == "Grad" && name.strip == "Nm"
        @gradient_names << text.strip
      end

      continue!(4 + size * 2)
    end

    private def parse_objc(name)
      object_name_length = current_slice_length
      continue!

      object_name = current_slice(object_name_length * 2).strip
      continue!(object_name_length * 2)

      object_type_length = current_slice_length
      object_type_length = 4 if object_type_length.zero?
      continue!

      object_type = current_slice(object_type_length).strip
      continue!(object_type_length)

      object_size = current_slice_length
      continue!

      @current_object_name = name.strip
      log(@current_object_name, "objc", object_size, object_type, object_name)

      case @current_object_name
      when "Grad"
        flush_current_gradient
      when "Clr"
        flush_current_color
        @current_color = { "palette" => object_type }
      end

      upshift!
      object_size.times { parse_entry if @offset < @buffer.length }
      downshift!
    end

    private def parse_untf(name)
      type = current_slice
      value = @buffer.slice(@offset + 4, 8).unpack("G").first
      log(name, "untf", type, value)

      if @current_object_name == "Clr" && COLOR_TERMS.include?(name.strip)
        @current_color[name.strip] = value
      end

      if @current_object_name == "Trns" && name == "Opct" && type == "#Prc"
        flush_current_transparency
        @current_transparency[name.strip] = value / 100
      end

      continue!(12)
    end

    private def parse_bool(name)
      value = @buffer.slice(@offset, 1).ord
      log(name, "bool", value)
      continue!(1)
    end

    private def parse_long(name)
      size = current_slice_length
      log(name, "long", size)

      if @current_object_name == "Clr" && name == "Lctn"
        @current_color[name.strip] = size
      end

      if @current_object_name == "Trns" && name == "Lctn"
        @current_transparency[name.strip] = size
      end

      continue!
    end

    private def parse_doub(name)
      value = current_float_slice
      log(name, "doub", value)

      if @current_object_name == "Clr" && COLOR_TERMS.include?(name.strip)
        @current_color[name.strip] = value
      end

      continue!(8)
    end

    private def parse_enum(name)
      size_a = current_slice_length
      continue!
      size_a = 4 if size_a.zero?
      name_a = current_slice(size_a)
      continue!(size_a)

      size_b = current_slice_length
      continue!
      size_b = 4 if size_b.zero?
      name_b = current_slice(size_b)
      continue!(size_b)

      log(name, "enum", name_a, name_b)
    end

    private def parse_tdta(name)
      size = current_slice_length
      continue!
      string = current_slice(size)
      continue!(size)
      log(name, "tdta", size, string)
    end

    # Sometimes the offset is off by one byte.
    # We roll back to the point before parsing an entry to try and parse it again.
    private def parse_unknown(name, rollback)
      @offset = rollback - 1
      parse_entry if @offset < @buffer.length
    end

  end
end


