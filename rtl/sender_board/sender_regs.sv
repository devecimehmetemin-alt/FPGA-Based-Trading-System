`default_nettype none

// AXI4-Lite control and status for the replay engine, single clock like book_regs.

module sender_regs #(
    parameter int ADDR_W = 8,
    parameter int AXI_ADDR_W = 40,
    parameter int NUM_EXTENTS = 2
)(
    input wire logic clk,
    input wire logic rst,

    input wire logic [ADDR_W-1:0] s_axi_awaddr,
    input wire logic s_axi_awvalid,
    output logic s_axi_awready,
    input wire logic [31:0] s_axi_wdata,
    input wire logic [3:0] s_axi_wstrb,
    input wire logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input wire logic s_axi_bready,
    input wire logic [ADDR_W-1:0] s_axi_araddr,
    input wire logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input wire logic s_axi_rready,

    output logic start,
    output logic [NUM_EXTENTS-1:0][AXI_ADDR_W-1:0] ext_base,
    output logic [NUM_EXTENTS-1:0][31:0] ext_beats,
    output logic [$clog2(NUM_EXTENTS+1)-1:0] ext_count,

    input wire logic busy,
    input wire logic done,
    input wire logic [31:0] frames_sent,
    input wire logic underrun,
    input wire logic resp_err,
    input wire logic fifo_overflow
);

    localparam logic [31:0] MAGIC = 32'h5345_4E44;
    localparam int EXT_BASE_WORD = 8;
    localparam int EXT_STRIDE = 4;
    localparam int CNT_W = $clog2(NUM_EXTENTS + 1);

    logic wr_go, rd_go;
    logic [5:0] wr_word, rd_word;

    assign wr_go = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_go;
    assign s_axi_wready = wr_go;
    assign wr_word = s_axi_awaddr[ADDR_W-1:2];

    assign rd_go = s_axi_arvalid && !s_axi_rvalid;
    assign s_axi_arready = rd_go;
    assign rd_word = s_axi_araddr[ADDR_W-1:2];

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_bvalid <= 1'b0;
            start <= 1'b0;
            ext_count <= '0;
            ext_base <= '0;
            ext_beats <= '0;
        end else begin
            start <= 1'b0;
            if (wr_go) begin
                s_axi_bvalid <= 1'b1;
                if (s_axi_wstrb[0]) begin
                    if (wr_word == 6'h1) start <= s_axi_wdata[0];
                    if (wr_word == 6'h4) ext_count <= s_axi_wdata[CNT_W-1:0];
                    for (int i = 0; i < NUM_EXTENTS; i++) begin
                        if (wr_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i))
                            ext_base[i][31:0] <= s_axi_wdata;
                        if (wr_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i + 1))
                            ext_base[i][AXI_ADDR_W-1:32] <= s_axi_wdata[AXI_ADDR_W-33:0];
                        if (wr_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i + 2))
                            ext_beats[i] <= s_axi_wdata;
                    end
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    logic [31:0] ext_read;

    always_comb begin
        ext_read = '0;
        for (int i = 0; i < NUM_EXTENTS; i++) begin
            if (rd_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i))
                ext_read = ext_base[i][31:0];
            if (rd_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i + 1))
                ext_read = {{(64 - AXI_ADDR_W){1'b0}}, ext_base[i][AXI_ADDR_W-1:32]};
            if (rd_word == 6'(EXT_BASE_WORD + EXT_STRIDE * i + 2))
                ext_read = ext_beats[i];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
        end else if (rd_go) begin
            s_axi_rvalid <= 1'b1;
            case (rd_word)
                6'h0: s_axi_rdata <= MAGIC;
                6'h2: s_axi_rdata <= {27'd0, fifo_overflow, resp_err,
                                      underrun, done, busy};
                6'h3: s_axi_rdata <= frames_sent;
                6'h4: s_axi_rdata <= {{(32 - CNT_W){1'b0}}, ext_count};
                default: s_axi_rdata <= ext_read;
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
