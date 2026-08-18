module tb_symbol_filter();

    localparam int MAXG = 8388608;
    localparam int MAXM = 262144;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, rec_valid, rec_side;
    logic [7:0] rec_type;
    logic [15:0] rec_locate;
    logic [47:0] rec_time;
    logic [63:0] rec_seq, rec_ref, rec_ref2, rec_stock;
    logic [31:0] rec_shares, rec_price;
    logic out_valid, out_side;
    logic [7:0] out_type;
    logic [15:0] out_locate;
    logic [47:0] out_time;
    logic [63:0] out_seq, out_ref, out_ref2, out_stock;
    logic [31:0] out_shares, out_price;

    logic [7:0] gold [0:MAXG-1];
    int moff [0:MAXM-1];
    logic [7:0] mtype [0:MAXM-1];
    logic [15:0] mloc [0:MAXM-1];
    bit lmap [0:65535];

    int n_gold = 0, n_want = 0;
    int sent = 0, got_af = 0, got_ref = 0, errors = 0;
    int exp_af = 0, exp_ref = 0;

    symbol_filter DUT(.*);

    function automatic logic wanted(input logic [63:0] s);
        wanted = (s == 64'h4141504C20202020);
    endfunction

    initial begin
        int fd, o, l, s;
        logic [63:0] sym;
        string ty;

        $readmemh("itch_expect.hex", gold);
        while (n_gold < MAXG && !$isunknown(gold[n_gold])) n_gold++;

        fd = $fopen("itch_expect.txt", "r");
        if (fd == 0) begin
            $display("cannot open itch_expect.txt");
            $finish;
        end
        while ($fscanf(fd, "%d %d %d %s", o, l, s, ty) == 4)
            if (ty == "A" || ty == "F" || ty == "E" || ty == "C" ||
                ty == "X" || ty == "D" || ty == "U") begin
                moff[n_want] = o;
                mtype[n_want] = gold[o];
                mloc[n_want] = {gold[o + 1], gold[o + 2]};
                if (ty == "A" || ty == "F") begin
                    sym = '0;
                    for (int i = 0; i < 8; i++) sym = {sym[55:0], gold[o + 24 + i]};
                    if (wanted(sym)) begin
                        lmap[int'(mloc[n_want])] = 1;
                        exp_af++;
                    end
                end else if (lmap[int'(mloc[n_want])]) exp_ref++;
                n_want++;
            end
        $fclose(fd);
        $display("loaded %0d golden bytes, %0d records of interest", n_gold, n_want);

        rst = 1; rec_valid = 0; rec_type = '0; rec_stock = '0; rec_seq = '0;
        rec_locate = '0; rec_time = '0; rec_ref = '0; rec_ref2 = '0;
        rec_shares = '0; rec_price = '0; rec_side = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int m = 0; m < n_want; m++) begin
            @(posedge clk); #1;
            rec_type = mtype[m];
            rec_locate = mloc[m];
            rec_stock = '0;
            if (mtype[m] == 8'h41 || mtype[m] == 8'h46)
                for (int i = 0; i < 8; i++)
                    rec_stock = {rec_stock[55:0], gold[moff[m] + 24 + i]};
            rec_seq = 64'(m);
            rec_valid = 1;
            sent++;
        end
        @(posedge clk); #1;
        rec_valid = 0;
        repeat (4) @(posedge clk);

        $display("sent=%0d/%0d passed A/F=%0d/%0d passed ref-only=%0d/%0d errors=%0d",
                 sent, n_want, got_af, exp_af, got_ref, exp_ref, errors);
        if (errors == 0 && sent == n_want && sent > 0 && got_af == exp_af && got_ref == exp_ref)
            $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (out_valid) begin
            if (out_type == 8'h41 || out_type == 8'h46) begin
                if (!wanted(out_stock)) begin
                    if (errors < 10)
                        $error("record %0d: passed unwanted symbol %h", out_seq, out_stock);
                    errors++;
                end
                got_af++;
            end else got_ref++;
        end
    end

endmodule
