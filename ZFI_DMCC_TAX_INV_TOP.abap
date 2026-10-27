*&---------------------------------------------------------------------*
*& Include          ZFI_DMCC_TAX_INV_TOP
*&---------------------------------------------------------------------*
TABLES: sscrfields.

INCLUDE <icon>.

*----------------------------------------------------------------------*
* Constants
*----------------------------------------------------------------------*
CONSTANTS:
  gc_formname   TYPE tdsfname   VALUE 'ZDMCC_FI_DOC',
  gc_curr1      TYPE waers      VALUE 'AED',
  gc_curr2      TYPE waers      VALUE 'USD',
  gc_tvarv_mail TYPE rvari_vnam VALUE 'ZDMCC_FI_DOC_INT_MAIL',
  gc_kappl_tx   TYPE kappl      VALUE 'TX',
  gc_koart_cust TYPE koart      VALUE 'D',
  gc_koart_vend TYPE koart      VALUE 'K',
  gc_koart_gl   TYPE koart      VALUE 'S',
  gc_buzid_tax  TYPE buzid      VALUE 'T'.

*----------------------------------------------------------------------*
* Types
*----------------------------------------------------------------------*
TYPES: ty_pct TYPE p LENGTH 7 DECIMALS 3.

TYPES: BEGIN OF ty_bkpf,
         bukrs TYPE bkpf-bukrs,
         belnr TYPE bkpf-belnr,
         gjahr TYPE bkpf-gjahr,
         blart TYPE bkpf-blart,
         budat TYPE bkpf-budat,
         xblnr TYPE bkpf-xblnr,
         waers TYPE bkpf-waers,
         hwaer TYPE bkpf-hwaer,
         hwae2 TYPE bkpf-hwae2,
         hwae3 TYPE bkpf-hwae3,
       END OF ty_bkpf.

TYPES: BEGIN OF ty_bseg,
         bukrs TYPE bseg-bukrs,
         belnr TYPE bseg-belnr,
         gjahr TYPE bseg-gjahr,
         buzei TYPE bseg-buzei,
         buzid TYPE bseg-buzid,
         koart TYPE bseg-koart,
         shkzg TYPE bseg-shkzg,
         mwskz TYPE bseg-mwskz,
         wrbtr TYPE bseg-wrbtr,
         dmbtr TYPE bseg-dmbtr,
         dmbe2 TYPE bseg-dmbe2,
         dmbe3 TYPE bseg-dmbe3,
         sgtxt TYPE bseg-sgtxt,
         kunnr TYPE bseg-kunnr,
         lifnr TYPE bseg-lifnr,
         rebzg TYPE bseg-rebzg,
         rebzj TYPE bseg-rebzj,
       END OF ty_bseg,
       ty_t_bseg TYPE STANDARD TABLE OF ty_bseg WITH DEFAULT KEY.

TYPES: BEGIN OF ty_t001,
         bukrs TYPE t001-bukrs,
         butxt TYPE t001-butxt,
         land1 TYPE t001-land1,
         adrnr TYPE t001-adrnr,
         stceg TYPE t001-stceg,
       END OF ty_t001.

* VAT rate buffer (per tax code)
TYPES: BEGIN OF ty_rate,
         mwskz TYPE mwskz,
         rate  TYPE ty_pct,
       END OF ty_rate.

TYPES: BEGIN OF ty_tax_cond,
         knumh TYPE konp-knumh,
         kbetr TYPE konp-kbetr,
       END OF ty_tax_cond.

* Raw (numeric) values per printable line - used for calculation only
TYPES: BEGIN OF ty_calc,
         sgtxt TYPE bseg-sgtxt,
         mwskz TYPE bseg-mwskz,
         rate  TYPE ty_pct,
         amt1  TYPE bseg-wrbtr,
         vat1  TYPE bseg-wrbtr,
         amt2  TYPE bseg-wrbtr,
         vat2  TYPE bseg-wrbtr,
       END OF ty_calc,
       ty_t_calc TYPE STANDARD TABLE OF ty_calc WITH DEFAULT KEY.

TYPES: ty_t_mail TYPE STANDARD TABLE OF ad_smtpadr WITH DEFAULT KEY.

* One complete form (per document) ready for output
TYPES: BEGIN OF ty_out,
         hdr  TYPE zst_dmcc_fi_hdr,
         itm  TYPE ztt_dmcc_fi_itm,
         mail TYPE ty_t_mail,          " Customer / vendor e-mail IDs
         warn TYPE bapi_msg,           " Non-blocking warning
       END OF ty_out.

TYPES: BEGIN OF ty_log,
         status  TYPE icon_d,
         bukrs   TYPE bukrs,
         belnr   TYPE belnr_d,
         gjahr   TYPE gjahr,
         blart   TYPE blart,
         message TYPE bapi_msg,
       END OF ty_log.

*----------------------------------------------------------------------*
* Global data
*----------------------------------------------------------------------*
DATA: gt_bkpf      TYPE STANDARD TABLE OF ty_bkpf,
      gt_bseg      TYPE STANDARD TABLE OF ty_bseg,
      gt_rate      TYPE STANDARD TABLE OF ty_rate,
      gt_out       TYPE STANDARD TABLE OF ty_out,
      gt_log       TYPE STANDARD TABLE OF ty_log,
      gs_t001      TYPE ty_t001,
      gv_comp_addr TYPE char255,
      gv_fm_name   TYPE rs38l_fnam,
      gv_belnr     TYPE bkpf-belnr,       " Selection screen reference
      gv_email     TYPE ad_smtpadr.       " Selection screen reference
