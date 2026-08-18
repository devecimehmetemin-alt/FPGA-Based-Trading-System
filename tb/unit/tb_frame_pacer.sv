module tb_frame_pacer();

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, req, grant;
    logic [31:0] period;

    int errors = 0;

    frame_pacer DUT(.*);

    // grant to grant, which is what the period means: the frame start rate, not
    // the gap left after a frame has drained
    task automatic spacing(input int p, input int want);
        int first, seen;
        first = -1;
        seen = 0;
        @(posedge clk); #1;
        period = 32'(p);
        req = 1'b1;
        for (int c = 0; c < 200 && seen < 4; c++) begin
            @(negedge clk);
            if (grant) begin
                if (first < 0) first = c;
                else begin
                    if ((c - first) != want) begin
                        $error("period %0d: grants %0d apart, expected %0d",
                               p, c - first, want);
                        errors++;
                    end
                    first = c;
                end
                seen++;
            end
        end
        @(posedge clk); #1;
        req = 1'b0;
        if (seen < 4) begin
            $error("period %0d: only %0d grants in 200 cycles", p, seen);
            errors++;
        end
    endtask

    initial begin
        int idle;

        rst = 1; req = 0; period = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // 0 and 1 both mean every cycle: cnt reloads to period-1, so 1 leaves it
        // already at zero
        spacing(0, 1);
        spacing(1, 1);
        spacing(2, 2);
        spacing(5, 5);
        spacing(17, 17);

        // no request, no grant, however long the counter has been idle
        @(posedge clk); #1;
        period = 32'd9;
        req = 1'b0;
        idle = 0;
        repeat (40) begin
            @(negedge clk);
            if (grant) idle++;
        end
        if (idle != 0) begin
            $error("granted %0d times with req low", idle);
            errors++;
        end

        // the counter runs during the idle gap, so a request arriving after the
        // period has already elapsed is granted at once
        @(posedge clk); #1;
        req = 1'b1;
        @(negedge clk);
        if (!grant) begin
            $error("late request not granted immediately");
            errors++;
        end

        // and a request arriving straight after a grant has to wait the balance
        @(posedge clk); #1;
        req = 1'b0;
        repeat (3) @(posedge clk);
        #1 req = 1'b1;
        @(negedge clk);
        if (grant) begin
            $error("granted %0d cycles into a 9 cycle period", 4);
            errors++;
        end

        $display("errors=%0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
