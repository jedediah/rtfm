require 'stringio'

class Object
  def singleton_class
    class << self; self; end
  end

  def singleton_method_defined? meth
    class << self; self; end.method_defined? meth
  end
end

module RTFM
  # Annotate the next method or constant defined:
  #   doc "description"
  #   doc { ... }
  #
  # Annotate an explicit method or constant:
  #   doc :thing, "description"
  #   doc(:thing) { ... }
  #
  # The block can contain the following:
  #   arg :argname
  #   arg :argname, "argument description"
  #   arg :argname, Type
  #   arg :argname, Type, "argument description"
  #   args :argname1 => "an untyped argument",
  #        :argname2 => { :type => Integer,
  #                       :default => 123,
  #                       :desc => "a typed argument" },
  #        :argname3 => [Integer,123,"lazy person version of above (put nil in empty fields)"]
  #
  #   returns "return value description"
  #   returns Type
  #   returns Type, "description"
  #   desc "method description"
  #   "method description in return value"
  def doc *a, &block
    # write the fucking manual
    @_rtfm ||= Manual.new(self)
    subj,desc = if a.size == 2 && !block_given?
                  # doc :thing, "desc"
                  a
                elsif a.size == 1 && a[0].is_a?(String) && !block_given?
                  # doc("desc")
                  [nil,a[0]]
                elsif a.empty? && block_given?
                  # doc { ... }
                  [nil,nil]
                else
                  raise ArgumentError.new "invalid annotation form"
                end

    if subj.nil?
      # forward ref to next method
      (@_rtfm_queue ||= []) << [{:name => nil, :desc => desc}, block]
    else
      subj,name = if subj.is_a? Module
                    # doc SomeModule (must be a Module or Class)
                    [subj,subj.name]
                  elsif subj.is_a? Symbol
                    [@_rtfm.resolve_subject(subj), subj.to_s]
                  else
                    raise ArgumentError.new "invalid document subject type #{subj.class}, must be a Module, Class or Symbol"
                  end

      if subj.is_a?(Symbol)
        # named forward method ref
        (@_rtfm_forward_refs ||= {})[subj] << [{:name => name, :desc => desc}, block]
      else
        # existing subject
        @_rtfm.annotate subj, {:name => name, :desc => desc}, &block
      end
    end
  end

  def doc? key, io=STDOUT
    # read the fucking manual
    ::RTFM.format rtfm.lookup(key), io
  end

  def rtfm
    @_rtfm ||= Manual.new(self)
  end

  def _rtfm_method_added sym, meth
    if !@_rtfm_queue.empty?
      until @_rtfm_queue.empty?
        opts, block = @_rtfm_queue.shift
        opts[:name] ||= sym.to_s
        @_rtfm.annotate meth, opts, &block
      end
    elsif @_rtfm_forward_refs.has_key? sym
      opts, block = @_rtfm_forward_refs.delete(sym)
      opts[:name] ||= sym.to_s
      @_rtfm.annotate meth, opts, &block
    end
  end

  def method_added meth
    super
    _rtfm_method_added meth, instance_method(meth)
  end

  def singleton_method_added meth
    super
    _rtfm_method_added meth, method(meth)
  end

  def self.format notes, xio=nil
    io = xio || StringIO.new
    notes.each do |n|
      if [:instance_method, :singleton_method].include?(n.type)
        io << "self." if n.type == :singleton_method
        io << "#{n.name}("

        arg_len = 0
        type_len = 0
        io << n.args.each_pair.map do |arg, info|
          arg_len = [arg_len, arg.size].max
          type_len = [type_len, info[:type].to_s.size].max if info[:type]
          x = arg.to_s
          x << "=#{info[:default]}" if info[:default]
          x
        end.join(", ")

        arg_desc_len = [78 - arg_len - type_len - 5, 12].max

        io << ")"
        io << " => #{n.returns[:type]}" if n.returns[:type]
        io << "\n"

        n.args.each_pair do |arg, info|
          io << "  #{arg.to_s.ljust arg_len}"
          io << " (#{info[:type].to_s})".ljust(type_len+3) if info[:type]

          if info[:desc]
            desc = info[:desc].word_wrap(arg_desc_len)
            io << " #{desc.lines.first.chomp}\n"
            desc.lines.to_a[1..-1].each do |l|
              io << ' '*(2+arg_len+1+type_len+1) + " #{l.chomp}\n"
            end
          end
        end
        
        if n.desc
          io << "\n"
          desc = n.desc.word_wrap(76)
          desc.each_line do |l|
            io << "  #{l.chomp}\n"
          end
        end
      end # if ...
    end # notes.each

    return io.string unless xio
  end

  # We only want to add singleton methods so we might as well override this.
  def self.append_features mod
    mod.extend self
  end

  class Manual
    attr_accessor :owner
    attr_reader :annotations

    def resolve_subject sym
      if sym =~ /^[A-Z]/
        # doc :SOME_CONSTANT
        @owner.const_get(sym)
      elsif @owner.method_defined? sym
        # doc :some_singleton_method
        @owner.instance_method sym
      elsif @owner.singleton_method_defined? sym
        # doc :some_instance_method
        @owner.method sym
        # else, forward method ref
      end
    end

    def initialize owner
      @owner = owner
      clear
    end

    def annotate subject, opts, &block
      opts = opts.dup
      opts[:type] ||= case subject
                      when Symbol
                        opts[:type]
                      when Class
                        :class
                      when Module
                        :module
                      when Method
                        :singleton_method
                      when UnboundMethod
                        :instance_method
                      end
      opts[:name] ||= subject.to_s
      @annotations[subject] << Annotation.new(opts[:name], opts, &block)
    end

    # Return an array of annotations for this subject
    def lookup sym
      @annotations[resolve_subject sym]
    end

    # Erase the entire manual
    def clear
      @annotations = Hash.new([])
    end
  end

  class Annotation
    def initialize name, opts, &block
      @name = name.to_s
      @type = opts[:type]
      @desc = opts[:desc]
      @args = {}
      @returns = {:type => nil, :desc => nil}

      if block_given?
        x = instance_eval(&block)
        @desc ||= x
      end
    end

    attr_reader :name

    def type t=nil
      if t
        @type = t
        return self
      else
        return @type
      end
    end

    def arg ident, *a
      if !a.empty?
        @args[ident] =
          if a.size == 3
            {:type => a[0],
             :default => a[1],
             :desc => a[2]}
          elsif a.size == 2
            {:type => a[0],
             :desc => a[1]}
          elsif a.size == 1
            if a[0].is_a? String
              {:desc => a[0]}
            else
              {:type => a[:type],
               :default => a[:default],
               :desc => a[:desc]}
            end
          end
        return self
      else
        return @args[ident]
      end
    end

    def args a=nil
      if a
        a.each_pair {|k,v| v.is_a?(Array) ? arg(k, *v) : arg(k, v) }
        return self
      else
        return @args
      end
    end

    def desc body=nil
      if body
        @desc = body.to_s
        return self
      else
        return @desc
      end
    end

    def returns type=nil, *args
      if type
        @returns = if args.empty? && type.is_a?(String)
                    {:type => nil, :desc => type}
                  else
                    {:type => type, :desc => args.first.to_s}
                  end
        return self
      else
        return @returns
      end
    end
  end
end

