module tb_book_regs();

    localparam int AW = 8;
    localparam logic [7:0] R_ID = 8'h00;
    localparam logic [7:0] R_CTRL = 8'h04;
    localparam logic [7:0] R_STATUS = 8'h08;
    localparam logic [7:0] R_BBOCNT = 8'h0C;
    localparam logic [7:0] R_BIDPX = 8'h10;
    localparam logic [7:0] R_BIDQTY = 8'h14;
    localparam logic [7:0] R_ASKPX = 8'h18;
    localparam logic [7:0] R_ASKQTY = 8'h1C;
    localparam logic [7:0] R_ORDERS = 8'h20;
    localparam logic [7:0] R_LEVELS = 8'h24;
    localparam logic [7:0] R_CGAP = 8'h30;
    localparam logic [7:0] R_CDUP = 8'h34;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst;
    logic [AW-1:0] s_axi_awaddr, s_axi_araddr;
    logic s_axi_awvalid, s_axi_awready, s_axi_wvalid, s_axi_wready;
    logic [31:0] s_axi_wdata, s_axi_rdata;
    logic [3:0] s_axi_wstrb;
    logic [1:0] s_axi_bresp, s_axi_rresp;
    logic s_axi_bvalid, s_axi_bready, s_axi_arvalid, s_axi_arready;
    logic s_axi_rvalid, s_axi_rready;

    logic bbo_valid, bid_live, ask_live, book_stale, degraded;
    logic [31:0] bid_price, bid_qty, ask_price, ask_qty;
    logic [17:0] store_occupancy;
    logic [15:0] lvl_occupancy;
    logic [63:0] gap_from;
    logic gap_pulse, dup_pulse, drop_pulse, pkt_bad, rec_err;
    logic rec_fifo_ovf, lvl_fifo_ovf, store_ovf, store_miss, store_dup;
    logic lvl_ovf, lvl_miss;
    logic resync;

    int errors = 0;

    book_regs #(.ADDR_W(AW)) DUT(.*);

    task automatic axi_write(input logic [AW-1:0] a, input logic [31:0] d);
        @(posedge clk); #1;
        s_axi_awaddr = a; s_axi_awvalid = 1'b1;
        s_axi_wdata = d; s_axi_wstrb = 4'hF; s_axi_wvalid = 1'b1;
        s_axi_bready = 1'b1;
        @(negedge clk);
        while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
        @(posedge clk); #1;
        s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
        @(negedge clk);
        while (!s_axi_bvalid) @(negedge clk);
        @(posedge clk); #1;
        s_axi_bready = 1'b0;
    endtask

    task automatic axi_read(input logic [AW-1:0] a, output logic [31:0] d);
        @(posedge clk); #1;
        s_axi_araddr = a; s_axi_arvalid = 1'b1; s_axi_rready = 1'b1;
        @(negedge clk);
        while (!s_axi_arready) @(negedge clk);
        @(posedge clk); #1;
        s_axi_arvalid = 1'b0;
        @(negedge clk);
        while (!s_axi_rvalid) @(negedge clk);
        d = s_axi_rdata;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;
    endtask

    task automatic expect_reg(input string nm, input logic [AW-1:0] a,
                              input logic [31:0] want);
        logic [31:0] got;
        axi_read(a, got);
        if (got !== want) begin
            $error("%s at 0x%02h: got %08h expected %08h", nm, a, got, want);
            errors++;
        end
    endtask

    task automatic pulse(ref logic sig, input int n);
        for (int i = 0; i < n; i++) begin
            @(posedge clk); #1;
            sig = 1'b1;
            @(posedge clk); #1;
            sig = 1'b0;
        end
    endtask

    initial begin
        rst = 1;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0; s_axi_awaddr = 0; s_axi_araddr = 0;
        s_axi_wdata = 0; s_axi_wstrb = 0;
        bbo_valid = 0; bid_live = 0; ask_live = 0; book_stale = 0; degraded = 0;
        bid_price = 0; bid_qty = 0; ask_price = 0; ask_qty = 0;
        store_occupancy = 0; lvl_occupancy = 0; gap_from = 0;
        gap_pulse = 0; dup_pulse = 0; drop_pulse = 0; pkt_bad = 0; rec_err = 0;
        rec_fifo_ovf = 0; lvl_fifo_ovf = 0; store_ovf = 0; store_miss = 0;
        store_dup = 0; lvl_ovf = 0; lvl_miss = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        expect_reg("ID", R_ID, 32'h424F_4F4B);

        // present a book, snapshot it, and read the shadow back
        @(posedge clk); #1;
        bid_live = 1; bid_price = 32'd1624500; bid_qty = 32'd1200;
        ask_live = 1; ask_price = 32'd1624600; ask_qty = 32'd800;
        store_occupancy = 18'd42521; lvl_occupancy = 16'd5659;
        degraded = 1;
        repeat (2) @(posedge clk);

        axi_write(R_CTRL, 32'h1);
        expect_reg("bid_price", R_BIDPX, 32'd1624500);
        expect_reg("bid_qty", R_BIDQTY, 32'd1200);
        expect_reg("ask_price", R_ASKPX, 32'd1624600);
        expect_reg("ask_qty", R_ASKQTY, 32'd800);
        expect_reg("orders", R_ORDERS, 32'd42521);
        expect_reg("levels", R_LEVELS, 32'd5659);
        expect_reg("status", R_STATUS, 32'hE);

        // the whole point of the shadow: the live book moving must not disturb a
        // read that is already in progress against an earlier snapshot
        @(posedge clk); #1;
        bid_price = 32'd1999999; ask_price = 32'd2999999; bid_qty = 32'd7;
        repeat (2) @(posedge clk);
        expect_reg("bid_price held", R_BIDPX, 32'd1624500);
        expect_reg("ask_price held", R_ASKPX, 32'd1624600);

        axi_write(R_CTRL, 32'h1);
        expect_reg("bid_price fresh", R_BIDPX, 32'd1999999);

        // counters accumulate on pulses and survive until a resync
        pulse(gap_pulse, 3);
        pulse(dup_pulse, 5);
        repeat (2) @(posedge clk);
        axi_write(R_CTRL, 32'h1);
        expect_reg("gap count", R_CGAP, 32'd3);
        expect_reg("dup count", R_CDUP, 32'd5);

        for (int i = 0; i < 4; i++) begin
            @(posedge clk); #1;
            bbo_valid = 1'b1;
            @(posedge clk); #1;
            bbo_valid = 1'b0;
        end
        repeat (2) @(posedge clk);
        axi_write(R_CTRL, 32'h1);
        expect_reg("bbo count", R_BBOCNT, 32'd4);

        // resync clears the counters and pulses the output for book_top
        axi_write(R_CTRL, 32'h2);
        repeat (3) @(posedge clk);
        axi_write(R_CTRL, 32'h1);
        expect_reg("gap after resync", R_CGAP, 32'd0);
        expect_reg("dup after resync", R_CDUP, 32'd0);
        expect_reg("bbo after resync", R_BBOCNT, 32'd0);

        expect_reg("unmapped", 8'h7C, 32'd0);

        $display("errors=%0d", errors);
        if (errors == 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    int resync_seen = 0;
    always @(negedge clk) if (resync) resync_seen++;

endmodule
