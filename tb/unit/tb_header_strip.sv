module tb_header_strip();

    localparam int MAXB = 32768;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, in_valid, in_last, in_fcs_ok;
    logic out_valid, out_last, out_fcs_ok, drop_pulse;
    logic [31:0] in_data, out_data;
    logic [3:0] in_keep, out_keep;

    logic [39:0] ebeat [0:MAXB-1];
    logic [39:0] gbeat [0:MAXB-1];
    int n_eth = 0, n_gold = 0, g = 0, errors = 0;

    header_strip DUT(.*);

    initial begin
        $readmemh("eth_beats.hex", ebeat);
        $readmemh("mold_beats.hex", gbeat);
        while (n_eth < MAXB && !$isunknown(ebeat[n_eth])) n_eth++;
        while (n_gold < MAXB && !$isunknown(gbeat[n_gold])) n_gold++;
        $display("loaded %0d input beats, %0d golden beats", n_eth, n_gold);

        rst = 1; in_valid = 0; in_data = '0; in_keep = '0; in_last = 0; in_fcs_ok = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int i = 0; i < n_eth; i++) begin
            @(posedge clk); #1;
            {in_fcs_ok, in_last, in_keep, in_data} = ebeat[i][37:0];
            in_valid = 1;
        end
        @(posedge clk); #1;
        in_valid = 0; in_last = 0;
        repeat (20) @(posedge clk);

        $display("checked=%0d/%0d errors=%0d", g, n_gold, errors);
        if (errors == 0 && g == n_gold && g > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (out_valid) begin
            if (g >= n_gold) begin
                if (errors < 10) $error("beat %0d: output past the end of the golden vector", g);
                errors++;
            end else if ({out_last, out_keep, out_data} !== gbeat[g][36:0]) begin
                if (errors < 10)
                    $error("beat %0d: got last=%0b keep=%b data=%08h expected last=%0b keep=%b data=%08h",
                           g, out_last, out_keep, out_data, gbeat[g][36], gbeat[g][35:32], gbeat[g][31:0]);
                errors++;
            end
            g++;
        end
    end

endmodule
