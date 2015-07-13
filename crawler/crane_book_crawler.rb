require 'crawler_rocks'
require 'pry'
require 'json'
require 'iconv'

require 'thread'
require 'thwait'

class CraneBookCrawler
  include CrawlerRocks::DSL

  ATTR_HASH = {
    "作者" => :author,
    "出版社" => :publisher,
    "出版日期" => :date,
    "ISBN" => :isbn,
    "代理商" => :agent,
  }

  def initialize
    @index_url = "http://www.crane.com.tw/ec99/crane/default.asp"
    @category_url = "http://www.crane.com.tw/ec99/crane/ShowCategory.asp?category_id="
  end

  def books
    @books = {}
    @detail_threads = []

    visit @index_url

    big_category_ids = [393, 41, 82, 106, 125, 145, 150, 156, 177, 258]
    big_category_ids.each { |category_id|
      parse_category("#{@category_url}#{category_id}")
    }

    ThreadsWait.all_waits(*@detail_threads)

    @books.values
  end

  def parse_category category_url
    r = RestClient.get category_url
    doc = Nokogiri::HTML(r)

    book_tables = doc.xpath('//table[@class="PageNavTable"][1]/following-sibling::table[1]')[0]
    if book_tables.nil?
      # 往下走
      doc.xpath('//a[@class="lef"]/@href').map{|href| URI.join(@index_url, href).to_s }.each {
        |category_url|
        parse_category(category_url)
      }

    else
      print "parse category: #{category_url}\n"
      # 開爬
      cookies = r.cookies

      # 第一頁
      parse_page(doc)

      # 第二頁之後
      doc.xpath('//select[@name="pageno"]')[0].xpath('option[position()>1]/@value').map(&:to_s).each do |pageno|
        # view_state = Hash[doc.css('input[type="hidden"]').map {|d| [d[:name], d[:value]]}]
        current_pageno = doc.xpath('//option[@selected]/@value')[0].to_s
        begin
          r = RestClient.post(category_url, {
            "select" => nil,
            "aclass" => nil,
            "mark" => nil,
            "prodColumn" => nil,
            "PageNum" => pageno,
            "action" => "pageform",
            "pageno" => current_pageno,
            "oby" => 1,
          }, cookies: cookies)  do |response, request, result, &block|
            if [301, 302, 307].include? response.code
              cookies = response.cookies
              response.follow_redirection(request, result, &block)
            else
              cookies = response.cookies
              response.return!(request, result, &block)
            end
          end
        rescue Exception => e
          next
        end
        doc = Nokogiri::HTML(r)

        parse_page(doc)
      end

    end
  end

  def parse_page doc
    book_tables = doc.xpath('//table[@class="PageNavTable"][1]/following-sibling::table[1]')[0]

    book_tables.xpath('tr[@valign="top"]/td/table').each do |book_table|

      # poor resolution
      # external_image_url = book_table.css('img').map{|img| URI.join(@index_url, img[:src]).to_s }.find{|src| src.include?('sImages')}

      datas = book_table.css('td.text1')[0]

      name = datas.css('a.goodsitem').text
      url = nil;
      url = URI.join(@index_url, datas.css('a.goodsitem')[0][:href].strip).to_s unless datas.css('a.goodsitem').empty?
      # id = url.match(/(?<=prod_id=).+/).to_s
      internal_code = datas.css('font.goodsmain').text
      price = datas.css('font.goodscostd').text.gsub(/[^\d]/, '').to_i

      @books[internal_code] = {
        name: name,
        url: url,
        internal_code: internal_code,
        price: price
      }

      # sleep(1) until (
      #   @detail_threads.delete_if { |t| !t.status };  # remove dead (ended) threads
      #   @detail_threads.count < (ENV['MAX_THREADS'] || 30)
      # )
      # @detail_threads << Thread.new do
        if url && url != @index_url
          r = RestClient.get url
          doc = Nokogiri::HTML(r)

          doc.css('span.defcxt').search('br').each{|br| br.replace("\n")}
          attr_datas = doc.css('span.defcxt').text.split("\n").map(&:strip).select{|d| !d.empty? }
          attr_datas.each{ |attr_data|
            key = ATTR_HASH[attr_data.rpartition('：')[0]]
            @books[internal_code][key] = attr_data.rpartition('：')[-1]
          }

          @books[internal_code][:external_image_url] = URI.join(@index_url, doc.xpath('//div[@id="image"]/img/@src').to_s.strip).to_s

          print "#{internal_code}\n"
        end

      # end # end thread
    end
  end
end

cc = CraneBookCrawler.new
File.write('crane_books.json', JSON.pretty_generate(cc.books))
