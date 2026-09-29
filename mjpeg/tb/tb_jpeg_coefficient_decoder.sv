`timescale 1ns/1ps
module tb_jpeg_coefficient_decoder;
    reg clk=0;always #5 clk=!clk;
    reg rst_n=0,start=0,gray=0;
    reg [7:0] s_data=0;reg s_valid=0,s_last=0,m_ready=0;
    wire s_ready,m_valid,done,error;wire [9:0] m_index;wire signed [15:0] m_value;
    jpeg_coefficient_decoder dut(.*);
    reg [7:0] data[0:65535];reg [9:0] indices[0:32767];reg [15:0] values[0:32767];
    reg [31:0] meta[0:194];
    reg [31:0] rng=32'h814734b1;
    integer case_id,byte_base,byte_len,expect_base,expect_len,received,sent,cycles,total_cycles=0;
    integer worst_cycles=0;
    string directory;
    always @(posedge clk) begin
        if(rst_n && !start) begin
            if(s_valid && s_ready) sent=sent+1;
            if(m_valid && m_ready) begin
                if(case_id<32 && (received>=expect_len || m_index!==indices[expect_base+received] ||
                   m_value!==values[expect_base+received]))
                    $fatal(1,"Case%0d sparse coefficient%0d expected index%0d value%h got index%0d value%h",
                        case_id,received,indices[expect_base+received],values[expect_base+received],m_index,m_value);
                received=received+1;
            end
        end
    end
    initial begin
        if(!$value$plusargs("vectors=%s",directory)) directory="vectors";
        $readmemh($sformatf("%s/data.hex",directory),data);$readmemh($sformatf("%s/index.hex",directory),indices);
        $readmemh($sformatf("%s/value.hex",directory),values);$readmemh($sformatf("%s/meta.hex",directory),meta);
        repeat(3) @(negedge clk);rst_n=1;
        for(case_id=0;case_id<39;case_id=case_id+1) begin
            @(negedge clk);start=1;s_valid=0;s_last=0;m_ready=0;
            gray=meta[case_id*5];byte_base=meta[case_id*5+1];byte_len=meta[case_id*5+2];
            expect_base=meta[case_id*5+3];expect_len=meta[case_id*5+4];sent=0;received=0;cycles=0;
            @(negedge clk);start=0;
            while(!done && cycles<100000) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                s_valid=sent<byte_len && rng[0:0];s_data=data[byte_base+sent];s_last=sent==byte_len-1;
                m_ready=rng[3:1]!=0;
                cycles=cycles+1;@(negedge clk);
            end
            s_valid=0;m_ready=0;
            if(!done || (case_id<32 && (error || received!=expect_len || sent!=byte_len)) ||
               (case_id>=32 && !error))
                $fatal(1,"Case%0d done%0d error%0d got%0d/%0d coefficients bytes%0d/%0d cycles%0d count%0d",case_id,done,error,received,expect_len,sent,byte_len,cycles,dut.bit_count);
            total_cycles=total_cycles+cycles;if(cycles>worst_cycles) worst_cycles=cycles;
            $display("Case%0d PASS bytes%0d coefficients%0d cycles%0d",case_id,byte_len,expect_len,cycles);
        end
        $display("DECODER_PASS valid32 malformed7 totalcycles%0d worstcycles%0d",total_cycles,worst_cycles);
        $finish;
    end
endmodule
