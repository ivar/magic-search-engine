require "strscan"
# Where's autoloader when we need it
require_relative "condition/condition"
require_relative "condition/condition_format"
require_relative "condition/condition_printed"
Dir["#{__dir__}/condition/condition_*.rb"].each do |path| require_relative path end

class QueryParser
  def parse(query_string)
    str = query_string.strip
    if str =~ /\A!(.*)\z/
      ConditionExact.new($1)
    else
      @tokens = tokenize(str)
      parse_query
    end
  end

private

  def tokenize(str)
    tokens = []
    s = StringScanner.new(str)
    until s.eos?
      if s.scan(/[\s,]+/)
        # pass
      elsif s.scan(/and\b/i)
        # and is default, skip it
      elsif s.scan(/or\b/i)
        tokens << [:or]
      elsif s.scan(%r[[/&]+]i)
        tokens << [:slash_slash]
      elsif s.scan(/-/)
        tokens << [:not]
      elsif s.scan(/\(/)
        tokens << [:open]
      elsif s.scan(/\)/)
        tokens << [:close]
      elsif s.scan(/t:(?:"(.*?)"|([’'\-\u2212\w\*]+))/i)
        tokens << [:test, ConditionTypes.new(s[1] || s[2])]
      elsif s.scan(/ft:(?:"(.*?)"|(\w+))/i)
        tokens << [:test, ConditionFlavor.new(s[1] || s[2])]
      elsif s.scan(/o:(?:"(.*?)"|([^\s\)]+))/i)
        tokens << [:test, ConditionOracle.new(s[1] || s[2])]
      elsif s.scan(/a:(?:"(.*?)"|(\w+))/i)
        tokens << [:test, ConditionArtist.new(s[1] || s[2])]
      elsif s.scan(/(banned|restricted|legal):(?:"(.*?)"|(\w+))/)
        klass = Kernel.const_get("Condition#{s[1].capitalize}")
        tokens << [:test, klass.new(s[2] || s[3])]
      elsif s.scan(/e:(?:"(.*?)"|(\w+))/i)
        tokens << [:test, ConditionEdition.new(s[1] || s[2])]
      elsif s.scan(/watermark:(?:"(.*?)"|(\w+))/i)
        tokens << [:test, ConditionWatermark.new(s[1] || s[2])]
      elsif s.scan(/f:(?:"(.*?)"|(\w+))/i)
        tokens << [:test, ConditionFormat.new(s[1] || s[2])]
      elsif s.scan(/b:(?:"(.*?)"|(\S+))/i)
        tokens << [:test, ConditionBlock.new(s[1] || s[2])]
      elsif s.scan(/c:([wubrgcml]+)/i)
        tokens << [:test, ConditionColors.new(s[1])]
      elsif s.scan(/ci:([wubrgcml]+)/i)
        tokens << [:test, ConditionColorIdentity.new(s[1])]
      elsif s.scan(/c!([wubrgcml]+)/i)
        tokens << [:test, ConditionColorsExclusive.new(s[1])]
      elsif s.scan(/(printed|firstprinted|lastprinted)\s*(>=|>|<=|<|=)\s*(\S+)/)
        klass = Kernel.const_get("Condition#{s[1].capitalize}")
        tokens << [:test, klass.new(s[2], s[3])]
      elsif s.scan(/r:(\S+)/)
        tokens << [:test, ConditionRarity.new(s[1])]
      elsif s.scan(/(pow|loyalty|tou|cmc|year)\s*(>=|>|<=|<|=)\s*(pow|tou|cmc|loyalty|year|-?\d+\.\d+|-?\.\d+|-?\d*½|-?\d+)\b/i)
        tokens << [:test, ConditionExpr.new(s[1], s[2], s[3])]
      elsif s.scan(/mana\s*(>=|>|<=|<|=)\s*((?:[\dwubrgxyz]|\{.*?\})+)/i)
        tokens << [:test, ConditionMana.new(s[1], s[2])]
      elsif s.scan(/(is|not):(vanilla|spell|permanent|funny|timeshifted|reserved|multipart)\b/i)
        tokens << [:not] if s[1].downcase == "not"
        klass = Kernel.const_get("ConditionIs#{s[2].capitalize}")
        tokens << [:test, klass.new]
      elsif s.scan(/(is|not):(split|flip|dfc)\b/i)
        tokens << [:not] if s[1].downcase == "not"
        tokens << [:test, ConditionLayout.new(s[2])]
      elsif s.scan(/layout:(normal|leveler|vanguard|dfc|token|split|flip|plane|scheme|phenomenon)/)
        tokens << [:test, ConditionLayout.new(s[1])]
      elsif s.scan(/(is|not):(old|new|future)\b/)
        tokens << [:not] if s[1].downcase == "not"
        tokens << [:test, ConditionFrame.new(s[2].downcase)]
      elsif s.scan(/(is|not):(black-bordered|silver-bordered|white-bordered)\b/i)
        tokens << [:not] if s[1].downcase == "not"
        tokens << [:test, ConditionBorder.new(s[2].sub("-bordered", "").downcase)]
      elsif s.scan(/"(.*?)"/)
        tokens << [:test, ConditionWord.new(s[1])]
      elsif s.scan(/not/)
        tokens << [:not]
      elsif s.scan(/other:/)
        tokens << [:other]
      elsif s.scan(/part:/)
        tokens << [:part]
      elsif s.scan(/([^-!<>=:"\s&\/][^!<>=:"\s&\/]*)(?=$|[\s&\/()])/i)
        # Veil-Cursed and similar silliness
        words = s[1].split("-")
        if words.size > 1
          tokens << [:open]
          words.each do |w|
            tokens << [:test, ConditionWord.new(w)]
          end
          tokens << [:close]
        else
          tokens << [:test, ConditionWord.new(s[1])]
        end
      else
        warn "Query parse error: #{str}"
        s.scan(/(\S+)/)
        tokens << [:test, ConditionWord.new(s[1])]
      end
    end
    tokens
  end

  def conds_to_query(conds)
    if conds.empty?
      nil
    elsif conds.size == 1
      conds[0]
    else
      ConditionAnd.new(*conds)
    end
  end

  def parse_query
    conds = []
    until @tokens.empty?
      case @tokens[0][0]
      when :close
        # Do ont eat token
        break
      when :or
        @tokens.shift
        # This is optimization,
        #   Condition.new(:or, [conds, right_conds])
        # would work just as well
        if conds.empty?
          # Ignore
        else
          right_query = parse_query
          if right_query
            return ConditionOr.new(conds_to_query(conds), right_query)
          else
            break
          end
        end
      when :slash_slash
        @tokens.shift
        # This is semantically meaningful
        left_query = conds_to_query(conds)
        right_query = parse_query
        if left_query and right_query
          return ConditionPart.new(ConditionAnd.new(left_query, ConditionOther.new(right_query)))
        else
          query = left_query || right_query
          if query
            return ConditionPart.new(query)
          else
            return ConditionIsMultipart.new
          end
        end
      # includes open / not
      else
        subquery = parse_cond
        if subquery
          conds << subquery
        else
          break
        end
      end
    end
    conds_to_query(conds)
  end

  def parse_cond
    return nil if @tokens.empty?
    case @tokens[0][0]
    when :open
      @tokens.shift
      subquery = parse_query
      @tokens.shift if @tokens[0] == [:close] # Ignore mismatched
      subquery
    when :close
      return
    when :not, :other, :part
      tok, = @tokens.shift
      cond = parse_cond
      if cond
        klass = Kernel.const_get("Condition#{tok.capitalize}")
        klass.new(cond)
      else
        # Parse error like "-)" or final "-"
        nil
      end
    when :or
      # Parse error like "- or"
      @tokens.shift
      parse_cond
    when :test
      @tokens.shift[1]
    else
      warn "Unknown token type #{@tokens[0]}"
    end
  end
end