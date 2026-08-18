module tb_sync_fifo();

    localparam int DATA_W = 32;
    localparam int ADDR_W = 5;
    localparam int DEPTH = 1 << ADDR_W;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, wr_valid, wr_ready, rd_ready, rd_valid, overflow;
    logic [DATA_W-1:0] wr_data, rd_data;
    logic [ADDR_W:0] level;

    int errors = 0, sent = 0, recv = 0;
    int model [$];

    sync_fifo #(.DATA_W(DATA_W), .ADDR_W(ADDR_W)) DUT (.*);

    initial begin
        rst = 1; wr_valid = 0; wr_data = 0; rd_ready = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int i = 0; i < DEPTH; i++) begin
            @(posedge clk); #1;
            wr_valid = 1; wr_data = 32'h1000 + i;
            @(negedge clk);
            if (!wr_ready) begin
                $error("wr_ready low at fill %0d, expected room", i);
                errors++;
            end
        end
        @(posedge clk); #1;
        wr_valid = 0;
        @(negedge clk);
        if (wr_ready) begin
            $error("wr_ready high after %0d writes, expected full", DEPTH);
            errors++;
        end
        if (level !== DEPTH) begin
            $error("level=%0d expected %0d", level, DEPTH);
            errors++;
        end

        @(posedge clk); #1;
        wr_valid = 1; wr_data = 32'hDEAD;
        @(posedge clk); #1;
        wr_valid = 0;
        @(negedge clk);
        if (!overflow) begin
            $error("overflow not asserted on a write while full");
            errors++;
        end

        for (int i = 0; i < DEPTH; i++) begin
            @(posedge clk); #1;
            rd_ready = 1;
            @(negedge clk);
            if (!rd_valid) begin
                $error("rd_valid low at drain %0d", i);
                errors++;
            end else if (rd_data !== 32'h1000 + i) begin
                $error("drain %0d: got %08h expected %08h", i, rd_data, 32'h1000 + i);
                errors++;
            end
        end
        @(posedge clk); #1;
        rd_ready = 0;
        @(negedge clk);
        if (rd_valid || level !== 0) begin
            $error("not empty after draining: rd_valid=%0b level=%0d", rd_valid, level);
            errors++;
        end

        fork
            begin
                for (int i = 0; i < 4000; i++) begin
                    @(posedge clk); #1;
                    wr_valid = ($urandom_range(0, 9) < 7);
                    wr_data = 32'h5000 + i;
                    @(negedge clk);
                    if (wr_valid && wr_ready) begin
                        model.push_back(32'h5000 + i);
                        sent++;
                    end else i--;
                end
                @(posedge clk); #1;
                wr_valid = 0;
            end
            begin
                repeat (9000) begin
                    @(posedge clk); #1;
                    rd_ready = ($urandom_range(0, 9) < 6);
                    @(negedge clk);
                    if (rd_valid && rd_ready) begin
                        if (model.size() == 0) begin
                            $error("read %08h with the model empty", rd_data);
                            errors++;
                        end else if (rd_data !== model[0]) begin
                            if (errors < 10)
                                $error("recv %0d: got %08h expected %08h",
                                       recv, rd_data, model[0]);
                            errors++;
                        end else void'(model.pop_front());
                        recv++;
                    end
                end
            end
        join

        @(posedge clk); #1;
        rd_ready = 1;
        while (rd_valid) begin
            @(negedge clk);
            if (rd_valid) begin
                if (rd_data !== model[0]) begin
                    if (errors < 10)
                        $error("tail %0d: got %08h expected %08h", recv, rd_data, model[0]);
                    errors++;
                end else void'(model.pop_front());
                recv++;
            end
            @(posedge clk); #1;
        end

        $display("sent=%0d recv=%0d left=%0d errors=%0d", sent, recv, model.size(), errors);
        if (errors == 0 && recv == sent && sent > 0 && model.size() == 0)
            $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
