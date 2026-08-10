`timescale 1ns/1ps
`default_nettype none

module tb_axis_cdc_fifo;

    localparam int  ADDR_W = 5;
    localparam int  DATA_W = 64;
    localparam int  KEEP_W = DATA_W/8;
    localparam int  DEPTH  = 1 << ADDR_W;
    localparam time STEP   = 1ns;

    logic wr_clk = 1'b0;
    logic rd_clk = 1'b0;
    always #4.000 wr_clk = ~wr_clk;
    always #3.300 rd_clk = ~rd_clk;

    logic              wr_reset, rd_reset;
    logic              wr_valid, wr_last, wr_fcs_ok, wr_ready, overflow;
    logic [DATA_W-1:0] wr_data;
    logic [KEEP_W-1:0] wr_keep;
    logic              rd_ready, rd_valid, rd_last, rd_fcs_ok;
    logic [KEEP_W-1:0] rd_keep;
    logic [DATA_W-1:0] rd_data;

    axis_cdc_fifo #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) dut (
        .wr_clk   (wr_clk),
        .wr_reset (wr_reset),
        .wr_valid (wr_valid),
        .wr_last  (wr_last),
        .wr_fcs_ok(wr_fcs_ok),
        .wr_data  (wr_data),
        .wr_keep  (wr_keep),
        .wr_ready (wr_ready),
        .overflow (overflow),
        .rd_clk   (rd_clk),
        .rd_reset (rd_reset),
        .rd_ready (rd_ready),
        .rd_valid (rd_valid),
        .rd_last  (rd_last),
        .rd_fcs_ok(rd_fcs_ok),
        .rd_keep  (rd_keep),
        .rd_data  (rd_data)
    );

    logic [DATA_W+KEEP_W+1:0] expected_q [$];
    int unsigned     errors = 0;
    int unsigned     checks = 0;
    string           phase  = "init";

    always @(posedge rd_clk) begin
        logic [DATA_W+KEEP_W+1:0] exp;
        if (!rd_reset && rd_valid && rd_ready) begin
            if (expected_q.size() == 0) begin
                $display("[%0t] FAIL (%s): word out of the FIFO with nothing expected: last=%0b fcs_ok=%0b keep=%04b data=%08h",
                         $time, phase, rd_last, rd_fcs_ok, rd_keep, rd_data);
                errors++;
            end else begin
                exp = expected_q.pop_front();
                if ({rd_last, rd_fcs_ok, rd_keep, rd_data} !== exp) begin
                    $display("[%0t] FAIL (%s): expected last=%0b fcs_ok=%0b keep=%04b data=%08h, got last=%0b fcs_ok=%0b keep=%04b data=%08h",
                             $time, phase, exp[DATA_W+KEEP_W+1], exp[DATA_W+KEEP_W], exp[DATA_W+KEEP_W-1:DATA_W], exp[DATA_W-1:0], rd_last, rd_fcs_ok, rd_keep, rd_data);
                    errors++;
                end
                checks++;
            end
        end
    end

    logic rd_stall_enable = 1'b0;

    initial begin
        rd_ready = 1'b0;
        forever begin
            @(posedge rd_clk);
            #STEP;
            rd_ready = rd_stall_enable ? ($urandom_range(0, 99) < 65) : 1'b1;
        end
    end

    task automatic send_frame(input int nwords, input bit good, input bit expect_commit);
        logic [DATA_W-1:0] d;
        logic [KEEP_W-1:0] k;
        logic              l;
        @(posedge wr_clk);
        #STEP;
        for (int i = 0; i < nwords; i++) begin
            d = {$urandom, $urandom};
            l = (i == nwords - 1);
            k = l ? ({KEEP_W{1'b1}} >> $urandom_range(0, KEEP_W-1)) : {KEEP_W{1'b1}};
            wr_valid  = 1'b1;
            wr_data   = d;
            wr_keep   = k;
            wr_last   = l;
            wr_fcs_ok = good;
            forever begin
                @(posedge wr_clk);
                if (wr_ready) break;
                #STEP;
            end
            #STEP;
            if (expect_commit) expected_q.push_back({l, good, k, d});
        end
        wr_valid  = 1'b0;
        wr_last   = 1'b0;
        wr_fcs_ok = 1'b0;
    endtask

    task automatic wait_drained(input int max_rd_cycles);
        int spun = 0;
        while (expected_q.size() != 0 && spun < max_rd_cycles) begin
            @(posedge rd_clk);
            spun++;
        end
        if (expected_q.size() != 0) begin
            $display("[%0t] FAIL (%s): %0d words never came out of the FIFO",
                     $time, phase, expected_q.size());
            errors++;
            expected_q.delete();
        end
    endtask

    task automatic check(input bit condition, input string what);
        if (!condition) begin
            $display("[%0t] FAIL (%s): %s", $time, phase, what);
            errors++;
        end
    endtask

    initial begin
        $dumpfile("tb_axis_cdc_fifo.vcd");
        $dumpvars(0, tb_axis_cdc_fifo);

        wr_reset  = 1'b1;
        rd_reset  = 1'b1;
        wr_valid  = 1'b0;
        wr_data   = '0;
        wr_keep   = '0;
        wr_last   = 1'b0;
        wr_fcs_ok = 1'b0;

        repeat (5) @(posedge wr_clk);
        #STEP wr_reset = 1'b0;
        repeat (5) @(posedge rd_clk);
        #STEP rd_reset = 1'b0;
        repeat (5) @(posedge wr_clk);

        phase = "single good frame";
        send_frame(4, 1'b1, 1'b1);
        wait_drained(2000);
        check(!overflow, "overflow set during normal traffic");

        phase = "back-to-back good frames";
        send_frame(3, 1'b1, 1'b1);
        send_frame(8, 1'b1, 1'b1);
        send_frame(1, 1'b1, 1'b1);
        wait_drained(4000);
        check(!overflow, "overflow set during normal traffic");

        phase = "bad FCS frame is forwarded";
        send_frame(6, 1'b0, 1'b1);
        wait_drained(2000);

        phase = "good frame after a bad one";
        send_frame(5, 1'b1, 1'b1);
        wait_drained(2000);

        phase = "oversized frame";
        send_frame(DEPTH + 8, 1'b1, 1'b1);
        wait_drained(4000);

        phase = "frame after oversized frame";
        send_frame(4, 1'b1, 1'b1);
        wait_drained(2000);

        phase = "read backpressure";
        rd_stall_enable = 1'b1;
        for (int i = 0; i < 12; i++)
            send_frame($urandom_range(1, 10), 1'b1, 1'b1);
        wait_drained(20000);
        rd_stall_enable = 1'b0;

        repeat (50) @(posedge rd_clk);

        $display("--------------------------------------------------");
        $display("checks compared : %0d", checks);
        $display("errors          : %0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else             $display("RESULT: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

    initial begin
        #2ms;
        $display("[%0t] FAIL: timeout in phase '%s'", $time, phase);
        $finish;
    end

endmodule

`default_nettype wire
