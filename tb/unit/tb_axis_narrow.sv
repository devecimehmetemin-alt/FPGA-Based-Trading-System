module tb_axis_narrow();

    localparam int WIDE_W = 128;
    localparam int HALF_W = WIDE_W / 2;
    localparam int NWORD = 500;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, in_valid, in_ready, out_valid, out_ready;
    logic [WIDE_W-1:0] in_data;
    logic [HALF_W-1:0] out_data;

    logic [WIDE_W-1:0] src [0:NWORD-1];
    int sent = 0, recv = 0, errors = 0;

    axis_narrow #(.WIDE_W(WIDE_W)) DUT(.*);

    initial begin
        for (int i = 0; i < NWORD; i++)
            src[i] = {$urandom, $urandom, $urandom, $urandom};

        rst = 1; in_valid = 0; in_data = '0; out_ready = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        fork
            begin : producer
                while (sent < NWORD) begin
                    @(posedge clk); #1;
                    in_valid = ($urandom_range(0, 9) < 7);
                    in_data = src[sent];
                    @(negedge clk);
                    if (in_valid && in_ready) sent++;
                end
                @(posedge clk); #1;
                in_valid = 0;
            end
            begin : consumer
                while (recv < 2 * NWORD) begin
                    @(posedge clk); #1;
                    out_ready = ($urandom_range(0, 9) < 6);
                    @(negedge clk);
                    if (out_valid && out_ready) begin
                        // low half of each wide word first, so the byte that sat
                        // lowest in DDR is the byte that leaves first
                        logic [HALF_W-1:0] want;
                        want = recv[0] ? src[recv / 2][WIDE_W-1:HALF_W]
                                       : src[recv / 2][HALF_W-1:0];
                        if (out_data !== want) begin
                            if (errors < 10)
                                $error("half %0d: got %032h expected %032h",
                                       recv, out_data, want);
                            errors++;
                        end
                        recv++;
                    end
                end
                @(posedge clk); #1;
                out_ready = 0;
            end
        join

        // the wide word must be held until both halves have gone, so the source
        // word count is exactly half the emitted count
        if (sent != NWORD) begin
            $error("consumed %0d wide words, expected %0d", sent, NWORD);
            errors++;
        end

        $display("wide=%0d halves=%0d errors=%0d", sent, recv, errors);
        if (errors == 0 && recv == 2 * NWORD) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    // a wide word may never be popped on the same beat as its low half
    always @(negedge clk) begin
        if (!rst && in_valid && in_ready && out_valid && out_ready) begin
            if (DUT.phase !== 1'b1) begin
                $error("wide word popped while sending the low half");
                errors++;
            end
        end
    end

endmodule
