require 'mock_redis/assertions'

class MockRedis
  module StringMethods
    include Assertions

    def append(key, value)
      assert_stringy(key)
      data[key] ||= ''
      data[key] << value
      data[key].length
    end

    def decr(key)
      decrby(key, 1)
    end

    def decrby(key, n)
      incrby(key, -n)
    end

    def get(key)
      assert_stringy(key)
      data[key]
    end

    def [](key)
      get(key)
    end

    def getbit(key, offset)
      assert_stringy(key)

      offset_of_byte = offset / 8
      offset_within_byte = offset % 8

      # String#getbyte would be lovely, but it's not in 1.8.7.
      byte = (data[key] || '').each_byte.drop(offset_of_byte).first

      if byte
        (byte & (2**7 >> offset_within_byte)) > 0 ? 1 : 0
      else
        0
      end
    end

    def getrange(key, start, stop)
      assert_stringy(key)
      (data[key] || '')[start..stop]
    end

    def getset(key, value)
      retval = get(key)
      set(key, value)
      retval
    end

    def incr(key)
      incrby(key, 1)
    end

    def incrby(key, n)
      assert_stringy(key)
      unless can_incr?(data[key])
        raise Redis::CommandError, 'ERR value is not an integer or out of range'
      end

      unless looks_like_integer?(n.to_s)
        raise Redis::CommandError, 'ERR value is not an integer or out of range'
      end

      new_value = data[key].to_i + n.to_i
      data[key] = new_value.to_s
      # for some reason, redis-rb doesn't return this as a string.
      new_value
    end

    def incrbyfloat(key, n)
      assert_stringy(key)
      unless can_incr_float?(data[key])
        raise Redis::CommandError, 'ERR value is not a valid float'
      end

      unless looks_like_float?(n.to_s)
        raise Redis::CommandError, 'ERR value is not a valid float'
      end

      new_value = data[key].to_f + n.to_f
      data[key] = new_value.to_s
      # for some reason, redis-rb doesn't return this as a string.
      new_value
    end

    def mget(*keys)
      assert_has_args(keys, 'mget')

      keys.map do |key|
        get(key) if stringy?(key)
      end
    end

    def mapped_mget(*keys)
      Hash[keys.zip(mget(*keys))]
    end

    def mset(*kvpairs)
      assert_has_args(kvpairs, 'mset')
      if kvpairs.length.odd?
        raise Redis::CommandError, 'ERR wrong number of arguments for MSET'
      end

      kvpairs.each_slice(2) do |(k,v)|
        set(k,v)
      end

      'OK'
    end

    def mapped_mset(hash)
      mset(*hash.to_a.flatten)
    end

    def msetnx(*kvpairs)
      assert_has_args(kvpairs, 'msetnx')

      if kvpairs.each_slice(2).any? { |(k,_)| exists(k) }
        false
      else
        mset(*kvpairs)
        true
      end
    end

    def mapped_msetnx(hash)
      msetnx(*hash.to_a.flatten)
    end

    def set(key, value, options = {})
      return_true = false
      options = options.dup
      if options.delete(:nx)
        if exists(key)
          return false
        else
          return_true = true
        end
      end
      if options.delete(:xx)
        if exists(key)
          return_true = true
        else
          return false
        end
      end
      data[key] = value.to_s

      # take latter
      expire_option = options.to_a.last
      if expire_option
        type, duration = expire_option
        if duration == 0
          raise Redis::CommandError, 'ERR invalid expire time in set'
        end
        expire(key, type.to_sym == :ex ? duration : duration / 1000.0)
      end
      return_true ? true : 'OK'
    end

    def []=(key, value, options = {})
      set(key, value, options)
    end

    def setbit(key, offset, value)
      assert_stringy(key, 'ERR bit is not an integer or out of range')
      retval = getbit(key, offset)

      str = data[key] || ''

      offset_of_byte = offset / 8
      offset_within_byte = offset % 8

      if offset_of_byte >= str.bytesize
        str = zero_pad(str, offset_of_byte+1)
      end

      char_index = byte_index = offset_within_char = 0
      str.each_char do |c|
        if byte_index < offset_of_byte
          char_index += 1
          byte_index += c.bytesize
        else
          offset_within_char = byte_index - offset_of_byte
          break
        end
      end

      char = str[char_index]
      char = char.chr if char.respond_to?(:chr)  # ruby 1.8 vs 1.9
      char_as_number = char.each_byte.reduce(0) do |a, byte|
        (a << 8) + byte
      end

      bitmask_length = (char.bytesize * 8 - offset_within_char * 8 - offset_within_byte - 1)
      bitmask = 1 << bitmask_length

      if value.zero?
        bitmask ^= 2**(char.bytesize * 8) - 1
        char_as_number &= bitmask
      else
        char_as_number |= bitmask
      end

      str[char_index] = char_as_number.chr

      data[key] = str
      retval
    end

    def bitcount(key, start = 0, stop = -1)
      assert_stringy(key)

      str   = data[key] || ''
      count = 0
      m1    = 0x5555555555555555
      m2    = 0x3333333333333333
      m4    = 0x0f0f0f0f0f0f0f0f
      m8    = 0x00ff00ff00ff00ff
      m16   = 0x0000ffff0000ffff
      m32   = 0x00000000ffffffff

      str.bytes.to_a[start..stop].each do |byte|
        # Naive Hamming weight
        c = byte
        c = (c & m1)  + ((c >> 1) & m1)
        c = (c & m2)  + ((c >> 2) & m2)
        c = (c & m4)  + ((c >> 4) & m4)
        c = (c & m8)  + ((c >> 8) & m8)
        c = (c & m16) + ((c >> 16) & m16)
        c = (c & m32) + ((c >> 32) & m32)
        count += c
      end

      count
    end

    def setex(key, seconds, value)
      set(key, value)
      expire(key, seconds)
      'OK'
    end

    def setnx(key, value)
      if exists(key)
        false
      else
        set(key, value)
        true
      end
    end

    def setrange(key, offset, value)
      assert_stringy(key)
      value = value.to_s
      old_value = (data[key] || '')

      prefix = zero_pad(old_value[0...offset], offset)
      data[key] = prefix + value + (old_value[(offset + value.length)..-1] || '')
      data[key].length
    end

    def strlen(key)
      assert_stringy(key)
      (data[key] || '').bytesize
    end




    private
    def stringy?(key)
      data[key].nil? || data[key].kind_of?(String)
    end

    def assert_stringy(key,
        message='WRONGTYPE Operation against a key holding the wrong kind of value')
      unless stringy?(key)
        raise Redis::CommandError, message
      end
    end

  end
end
